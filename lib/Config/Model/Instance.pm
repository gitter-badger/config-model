package Config::Model::Instance;

#use Scalar::Util qw(weaken) ;
use strict;

use 5.10.1;
use Mouse;
use Mouse::Util::TypeConstraints;
use MouseX::StrictConstructor;
with "Config::Model::Role::NodeLoader";

use Text::Diff;
use File::Path;
use Log::Log4perl qw(get_logger :levels);

use Config::Model::Annotation;
use Config::Model::Exception;
use Config::Model::Node;
use Config::Model::Loader;
use Config::Model::SearchElement;
use Config::Model::Iterator;
use Config::Model::ObjTreeScanner;

use warnings ;

use Carp qw/carp croak confess cluck/;

my $logger        = get_logger("Instance");
my $change_logger = get_logger("Anything::Change");

has [qw/root_class_name/] => ( is => 'ro', isa => 'Str', required => 1 );

sub location { return "in instance" }

has config_model => (
    is       => 'ro',
    isa      => 'Config::Model',
    weak_ref => 1,
    required => 1
);

has check => (
    is      => 'ro',
    isa     => 'Str',
    default => 'yes',
    reader  => 'read_check',
);

has auto_create => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

# a unique (instance wise) placeholder for various tree objects
# to store information
has _safe => (
    is      => 'rw',
    isa     => 'HashRef',
    traits  => ['Hash'],
    default => sub { {} },
    handles => {
        data => 'accessor',
    },
);

# preset mode:  to load values found by HW scan or other automatic scheme
# layered mode: to load values found in included files (e.g. a la multistrap)
has [qw/preset layered/] => (
    is      => 'ro',
    isa     => 'Bool',
    default => 0,
);

has changes => (
    is      => 'ro',
    isa     => 'ArrayRef',
    traits  => ['Array'],
    default => sub { [] },
    handles => {
        add_change => 'push',
        c_count    => 'count',

        #needs_save => 'count' ,
        clear_changes => 'clear',
    } );

sub needs_save {
    my $self = shift;
    my $arg  = shift;
    if ( defined $arg ) {
        if ($arg) {
            carp "replace needs_save(1) call with add_change";
            $self->add_change();    # may not work
        }
        else {
            carp "replace needs_save(0) call with clear_changes";
            $self->clear_changes;
        }
    }
    return $self->c_count;
}

has errors => (
    is      => 'ro',
    isa     => 'HashRef',
    traits  => ['Hash'],
    default => sub { {} },
    handles => {
        _set_error   => 'set',
        cancel_error => 'delete',
        has_error    => 'count',
        clear_errors => 'clear',
        error_paths  => 'keys'
    } );

sub add_error {
    my $self = shift;
    $self->_set_error( shift, '' );
}

sub error_messages {
    my $self = shift;
    my @errs = map { "$_: " . $self->config_root->grab($_)->error_msg } $self->error_paths;
    return wantarray ? @errs : join( "\n", @errs );
}

sub has_warning {
    my $self = shift;

    my $count_leaf_warnings = sub {
        my ( $scanner, $data_ref, $node, $element_name, $index, $leaf_object ) = @_;
        $$data_ref += $leaf_object->has_warning;
    };

    my $count_list_warnings = sub {
        my ( $scanner, $data_ref, $node, $element_name, $index, $leaf_object ) = @_;
        $$data_ref += $node->fetch_element($element_name)->has_warning;
    };

    my $scan = Config::Model::ObjTreeScanner->new(
        leaf_cb           => $count_leaf_warnings,
        list_element_hook => $count_list_warnings,
        hash_element_hook => $count_list_warnings,
    );

    my $result = 0;
    $scan->scan_node( \$result, $self->config_root );

    return $result;
}

has on_change_cb => (
    is  => 'rw',
    traits    => ['Code'],
    isa       => 'CodeRef',
    default   => sub { sub { } },
);

has on_message_cb => (
    traits    => ['Code'],
    is        => 'rw',
    isa       => 'CodeRef',
    default   => sub { sub { say @_; } },
    handles   => {
        show_message => 'execute',
    },
);

# initial_load mode: when data is loaded the first time
has initial_load => (
    is      => 'rw',
    isa     => 'Bool',
    default => 0,
    trigger => \&_trace_initial_load,
    traits  => [qw/Bool/],
    handles => {
        initial_load_start => 'set',
        initial_load_stop  => 'unset',
    } );

sub _trace_initial_load {
    my ( $self, $n, $o ) = @_;
    $logger->debug("switched to $n");
}

# This array holds a set of sub ref that will be invoked when
# the users requires to write all configuration tree in their
# backend storage.
has _write_back => (
    is      => 'ro',
    isa     => 'ArrayRef',
    traits  => ['Array'],
    handles => {
        register_write_back => 'push',
        count_write_back    => 'count',    # mostly for tests
    },
    default => sub { [] },
);

# used for auto_read auto_write feature
has [qw/name application root_dir backend backup/] => (
    is  => 'ro',
    isa => 'Maybe[Str]',
);

has read_root_dir => (
    is  => 'ro',
    isa => 'Str',
    lazy_build => 1,
);

sub _build_read_root_dir {
    my $self = shift;
    my $root_dir = $self->root_dir // '';
    # cleanup paths
    $root_dir .= '/' if $root_dir and $root_dir !~ m!/$! ;
    return $root_dir;
}

# config_file cannot be a Path::Tiny object: it may be a file name
# relative to a directory only known by a backend (e.g. a patch in
# debian/patches directory)
has config_file => (is  => 'ro', isa => 'Maybe[Str]');

has config_dir => (is  => 'ro', isa => 'Maybe[Str]');

has skip_read => ( is => 'ro', isa => 'Bool', default => 0 );

has tree => (
    is      => 'ro',
    isa     => 'Config::Model::Node',
    builder => 'reset_config',
    reader  => 'config_root',
    handles => [qw/apply_fixes/],
);

sub reset_config {
    my $self = shift;

    warn "skip_read is deprecated" if $self->skip_read;

    return $self->load_node (
        config_class_name => $self->{root_class_name},
        instance          => $self,
        container         => $self,
        skip_read         => $self->skip_read,
        check             => $self->read_check,
        config_file       => $self->{config_file},
    );
}

sub preset_start {
    my $self = shift;
    $logger->info("Starting preset mode");
    carp "Cannot start preset mode during layered mode"
        if $self->{layered};
    $self->{preset} = 1;
}

sub preset_stop {
    my $self = shift;
    $logger->info("Stopping preset mode");
    $self->{preset} = 0;
}

sub preset_clear {
    my $self = shift;

    my $leaf_cb = sub {
        my ( $scanner, $data_ref, $node, $element_name, $index, $leaf_object ) = @_;
        $leaf_object->clear_preset;
    };

    $self->_stuff_clear($leaf_cb);
}

sub layered_start {
    my $self = shift;
    $logger->info("Starting layered mode");
    carp "Cannot start layered mode during preset mode"
        if $self->{preset};
    $self->{layered} = 1;
}

sub layered_stop {
    my $self = shift;
    $logger->info("Stopping layered mode");
    $self->{layered} = 0;
}

sub layered_clear {
    my $self = shift;

    my $leaf_cb = sub {
        my ( $scanner, $data_ref, $node, $element_name, $index, $leaf_object ) = @_;
        $$data_ref ||= $leaf_object->clear_layered;
    };

    $self->_stuff_clear($leaf_cb);
}

sub get_data_mode {
    my $self = shift;
    return
          $self->{layered} ? 'layered'
        : $self->{preset}  ? 'preset'
        :                    'normal';
}

sub _stuff_clear {
    my ( $self, $leaf_cb ) = @_;

    # this sub may remove hash keys that were entered by user if the
    # corresponding hash value has no data.
    # it also clear auto_created ids if there's no data in there
    my $h_cb = sub {
        my ( $scanner, $data_ref, $node, $element_name, @keys ) = @_;
        my $obj = $node->fetch_element($element_name);

        foreach my $k (@keys) {
            my $has_data = 0;
            $scanner->scan_hash( \$has_data, $node, $element_name, $k );
            $obj->remove($k) unless $has_data;
            $$data_ref ||= $has_data;
        }
    };

    my $wiper = Config::Model::ObjTreeScanner->new(
        fallback        => 'all',
        auto_vivify     => 0,
        check           => 'skip',
        leaf_cb         => $leaf_cb,
        hash_element_cb => $h_cb,
        list_element_cb => $h_cb,
    );

    $wiper->scan_node( undef, $self->config_root );

}

sub modify {
    my $self = shift ;
    my %args   = @_ eq 1 ? ( step => $_[0] ) : @_;
    my $force = delete $args{force_save} || delete $args{force};
    $self->load(%args)->write_back( force => $force );
    return $self;
}

sub load {
    my $self   = shift;
    my $loader = Config::Model::Loader->new;
    my %args   = @_ eq 1 ? ( step => $_[0] ) : @_;
    $loader->load( node => $self->{tree}, %args );
    return $self;
}

sub search_element {
    my $self = shift;
    $self->{tree}->search_element(@_);
}

sub wizard_helper {
    carp __PACKAGE__, "::wizard_helper helped is deprecated. Call iterator instead";
    goto &iterator;
}

sub iterator {
    my $self = shift;
    my @args = @_;

    my $tree_root = $self->config_root;

    return Config::Model::Iterator->new( root => $tree_root, @args );
}

sub read_directory {
    carp "read_directory is deprecated";
    return shift->read_root_dir;
}

sub write_directory {
    my $self = shift;
    carp "write_directory is deprecated";
    return $self->read_root_dir;
}

sub write_root_dir {
    my $self = shift;
    return $self->read_root_dir;
}

# FIXME: record changes to implement undo/redo ?
sub notify_change {
    my $self = shift;
    my %args = @_;
    if ( $change_logger->is_debug ) {
        $change_logger->debug( "in instance ", $self->name, ' for path ', $args{path} );
    }

    foreach my $obsolete (qw/note_only msg/) {
        if ( my $m = delete $args{$obsolete} ) {
            carp "notify_change: param $obsolete is obsolete ($m)";
            $args{note} //='';
            $args{note} .= $m;
        }
    }

    $self->add_change( \%args );
    $self->on_change_cb->( %args );
}

sub list_changes {
    my $self = shift;
    my $l    = $self->changes;
    my @all;

    foreach my $c (@$l) {
        my $path = $c->{path} ;
        $path .= ': ' if $path;

        my $vt = $c->{value_type} || '';
        my ( $o, $n ) = map { $_ // '<undef>'; } ( $c->{old}, $c->{new} );

        if ( $vt eq 'string' and ( $o =~ /\n/ or $n =~ /\n/ ) ) {
            # append \n if needed so diff works as expected
            map { $_ .= "\n" unless /\n$/; } ( $o, $n );
            my $diff = diff \$o, \$n;
            push @all, $path . ( $c->{note} ? " # $c->{note}" : '' ) . "\n" . $diff;
        }
        elsif ( defined $c->{old} or defined $c->{new} ) {
            map { s/\n.*/.../s; } ( $o, $n );
            push @all, $path."'$o' -> '$n'" . ( $c->{note} ? " # $c->{note}" : '' );
        }
        elsif (defined $c->{note}){
            push @all, $path.$c->{note};
        }
        else {
            # something's unexpected with the call to notify_change
            push @all, "changed ".join(' ', each %$c);
        }
    }

    return wantarray ? @all : join( "\n", @all );
}

sub say_changes {
    my $self    = shift;
    my @changes = $self->list_changes;
    say "\n",
        join( "\n- ", "Changes applied to " . ($self->application // $self->name) . " configuration:", @changes ),
        "\n"
        if @changes;
    return @changes;
}

sub write_back {
    my $self = shift;
    my %args =
          scalar @_ > 1 ? @_
        : scalar @_ == 1 ? ( config_dir => $_[0] )
        :                  ();

    my $force_backend = delete $args{backend} || $self->{backend};
    my $force_write   = delete $args{force}   || 0;

    # make sure that root node is loaded
    $self->config_root->init;

    if ($force_write) {
        # make sure that the whole tree is loaded
        my $dump = $self->config_root->dump_tree;
    }

    foreach ( keys %args ) {
        if (/^(root|config_dir)$/) {
            $args{$_} ||= '';
            $args{$_} .= '/' if $args{$_} and $args{$_} !~ m(/$);
        }
        elsif ( not /^config_file$/ ) {
            croak "write_back: wrong parameters $_";
        }
    }

    if (not @{ $self->{_write_back} }) {
        my $info = $self->application ? "the model of application ".$self->application
            : "model ".$self->root_cladd_name ;
        croak "Don't know how to save data of $self->{name} instance. Either $info has no configured ",
            "read/write backend or no node containing a backend was loaded. ",
            "Try with -force option or add read/write backend to $info\n";
    }

    foreach my $path ( @{ $self->{_write_back} } ) {
        $logger->info("write_back called on node $path");
        my $node = $self->config_root->grab( step => $path, type => 'node' );
        $node->write_back(
            %args,
            config_file => $self->{config_file},
            backend     => $force_backend,
            force       => $force_write,
            backup      => $self->backup,
        );
    }
    $self->clear_changes;
}

sub save {
    goto &write_back;
}

sub update {
    my ($self, %args) = @_;

    my @msgs ;
    my $hook = sub {
        my ($scanner, $data_ref,$node,@element_list) = @_;
        if ($node->can('update')) {
            say "Calling update on ",$node->name, ' ',$node->config_class_name, " $node"
                unless $args{quiet};
            push (@msgs, $node->update(%args))
        } ;
    };

    my $root = $self->config_root ;

    Config::Model::ObjTreeScanner->new(
        node_content_hook => $hook,
        leaf_cb => sub { }
    )->scan_node( \@msgs, $root );

    return @msgs;
}

__PACKAGE__->meta->make_immutable;

1;

# ABSTRACT: Instance of configuration tree

__END__

=head1 SYNOPSIS

 use Config::Model;
 use File::Path ;

 # setup a dummy popcon conf file
 my $wr_dir = '/tmp/etc/';
 my $conf_file = "$wr_dir/popularity-contest.conf" ;

 unless (-d $wr_dir) {
     mkpath($wr_dir, { mode => 0755 }) 
       || die "can't mkpath $wr_dir: $!";
 }
 open(my $conf,"> $conf_file" ) || die "can't open $conf_file: $!";
 $conf->print( qq!MY_HOSTID="aaaaaaaaaaaaaaaaaaaa"\n!,
   qq!PARTICIPATE="yes"\n!,
   qq!USEHTTP="yes" # always http\n!,
   qq!DAY="6"\n!);
 $conf->close ;

 my $model = Config::Model->new;

 # PopCon model is provided. Create a new Config::Model::Instance object
 my $inst = $model->instance (root_class_name   => 'PopCon',
                              root_dir          => '/tmp',
                             );
 my $root = $inst -> config_root ;

 print $root->describe;



=head1 DESCRIPTION

This module provides an object that holds a configuration tree.

=head1 CONSTRUCTOR

An instance object is created by calling L<instance
method|Config::Model/"Configuration instance"> on an existing
model. This model can be specified by its application name:

 my $inst = $model->instance (
   # run 'cme list' to get list of applications
   application => 'foo',
   # optional
   instance_name => 'test1'
 );

 my $inst = $model->instance (
   root_class_name => 'SomeRootClass',
   instance_name => 'test1'
 );

The directory (or directories) holding configuration files is
specified within the configuration model. For test purpose you can
change the "root" directory with C<root_dir> parameter:

=over

=item root_dir

Pseudo root directory where to read I<and> write configuration
files. Configuration directory specified in model or with
C<config_dir> option is appended to this root directory

=item config_dir

Directory to read or write configuration file. This parameter must be
supplied if not provided by the configuration model.

=item backend

Specify which backend to use. See L</write_back ( ... )> for details

=item skip_read

DEPRECATED. When set, configuration files are not read when
creating configuration tree.

=item check

Specify whether to check value while reading config files. Either:

=over

=item yes

Check value and throws an error for bad values.

=item skip

Check value and skip bad value.

=item no

Do not check.

=back

=item on_change_cb

Call back this function whenever C<notify_change> is called. Called with
arguments: C<< name => <root node element name>, index => <index_value> >>

=item on_message_cb

Call back this function when L<show_message> is called. By default,
messages are displayed on STDOUT.

=item error_paths

Returns a list of tree items that currently have an error.

=item error_messages

Returns a list of error messages from the tree content.

=back

Note that the root directory specified within the configuration model
is overridden by C<root_dir> parameter.

If you need to load configuration data that are not correct, you can
use C<< force_load => 1 >>. Then, wrong data are discarded (equivalent to
C<check => 'no'> ).

=head1 METHODS

=head2 Manage configuration data

=head2 modify ( ... )

Calls L</"load(...)"> and then L</save>.

Takes the same parameter as C<load> plus C<force_write> to force
saving configuration file even if no value was modified (default is 0)

=head2 load ( ... )

Load configuration tree with configuration data. See
L<Config::Model::Loader/"load ( ... )"> for parameters.
Returns <$self>.

=head2 save ( ... )

Save the content of the configuration tree to
configuration files. (alias to C<write_back>)

=head2 config_root()

Returns the L<root object|Config::Model::Node> of the configuration tree.

=head2 apply_fixes

Scan the tree and apply fixes that are attached to warning specifications. 
See C<warn_if_match> or C<warn_unless_match> in L<Config::Model::Value/>.

=head2 needs_save

Returns 1 (or more) if the instance contains data that needs to be
saved. I.e some change were done in the tree that needs to be saved.

=head2 list_changes

In list context, returns a array ref of strings describing the changes. 
In scalar context, returns a big string. Useful to print.

=head2 say_changes

Print all changes on STDOUT and return the list of changes.

=head2 has_warning

Returns the number of warning found in the elements of this configuration instance.

=head2 update( quiet => (0|1), %args )

Try to run update command on all nodes of the configuration tree. Node
without C<update> method are ignored. C<update> prints a message
otherwise (unless C<quiet> is true).

=head2 searcher ( )

Returns an object dedicated to search an element in the configuration
model (respecting privilege level).

This method returns a L<Config::Model::Searcher> object. See
L<Config::Model::Searcher> for details on how to handle a search.

=head2 iterator 

This method returns a L<Config::Model::Iterator> object. See
L<Config::Model::Iterator> for details.

Arguments are explained in  L<Config::Model::Iterator>
L<constructor arguments|Config::Model::Iterator/"Creating an iterator">.

=head2 application

Returns the application name of the instance. (E.g C<popcon>, C<dpkg> ...)

=head2 wizard_helper ( ... )

Deprecated. Call L</iterator> instead.

=head1 Internal methods

=head2 name()

Returns the instance name.

=head2 read_check()

Returns which kind of check is performed while reading configuration
files. (see C<check> parameter in L</CONSTRUCTOR> section)

=head2 show_message( string )

Display the message on STDOUT unless a custom function was passed to
C<on_message_cb> parameter.

=head2 reset_config

Destroy current configuration tree (with data) and returns a new tree with
data (and annotations) loaded from disk.

=head2 config_model()

Returns the model (L<Config::Model> object) of the configuration tree.

=head2 annotation_saver()

Returns the object loading and saving annotations. See
L<Config::Model::Annotation> for details.

=head2 preset_start ()

All values stored in preset mode are shown to the user as default
values. This feature is useful to enter configuration data entered by
an automatic process (like hardware scan)

=head2 preset_stop ()

Stop preset mode

=head2 preset ()

Get preset mode

=head2 preset_clear()

Clear all preset values stored.

=head2 layered_start ()

All values stored in layered mode are shown to the user as default
values. This feature is useful to enter configuration data entered by
an automatic process (like hardware scan)

=head2 layered_stop ()

Stop layered mode

=head2 layered ()

Get layered mode

=head2 layered_clear()

Clear all layered values stored.

=head2 get_data_mode 

Returns 'normal' or 'preset' or 'layered'. Does not take into account initial_load.

=head2 initial_load_stop ()

Stop initial_load mode. Instance is built with initial_load as 1. Read backend
clears this value once the first read is done.

=head2 initial_load ()

Get initial_load mode

=head2 data( kind, [data] )

The data method provide a way to store some arbitrary data in the
instance object.


=head1 Auto read and write feature

Usually, a program based on config model must first create the
configuration model, then load all configuration data. 

This feature enables you to declare with the model a way to load
configuration data (and to write it back). See
L<Config::Model::BackendMgr> for details.

=head2 backend()

Get the preferred backend method for this instance (as passed to the
constructor).

=head2 root_dir()

Returns root directory where configuration data is read from or written to.

=head2 register_write_back ( node_location )

Register a node path that is called back with
C<write_back> method.

=head2 notify_change

Notify that some data has changed in the tree. See
L<Config::Model::AnyThing/notify_change(...)> for more details.

=head2 write_back ( ... )

In summary, save the content of the configuration tree to
configuration files.

In more details, C<write_back> trie to run all subroutines registered
with C<register_write_back> to write the configuration information
until one succeeds (returns true). (See L<Config::Model::BackendMgr>
for details).

You can specify here a pseudo root directory or another config
directory to write configuration data back with C<root> and
C<config_dir> parameters. This overrides the model specifications.

You can force to use a backend by specifying C<< backend => xxx >>. 
For instance, C<< backend => 'augeas' >> or C<< backend => 'custom' >>.

You can force to use all backend to write the files by specifying 
C<< backend => 'all' >>.

C<write_back> croaks if no write call-back are known.

=head1 AUTHOR

Dominique Dumont, (ddumont at cpan dot org)

=head1 SEE ALSO

L<Config::Model>, 
L<Config::Model::Node>, 
L<Config::Model::Loader>,
L<Config::Model::Searcher>,
L<Config::Model::Value>,

=cut
