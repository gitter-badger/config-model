[
  {
    'class_description' => 'generated from LCDd.conf',
    'name' => 'LCDd::MD8800',
    'element' => [
      'Device',
      {
        'value_type' => 'uniline',
        'upstream_default' => '/dev/ttyS1',
        'type' => 'leaf',
        'description' => 'device to use '
      },
      'Size',
      {
        'value_type' => 'uniline',
        'upstream_default' => '16x2',
        'type' => 'leaf',
        'description' => 'display size '
      },
      'Brightness',
      {
        'value_type' => 'integer',
        'min' => '0',
        'upstream_default' => '1000',
        'max' => '1000',
        'type' => 'leaf',
        'description' => 'Set the initial brightness '
      },
      'OffBrightness',
      {
        'value_type' => 'integer',
        'min' => '0',
        'upstream_default' => '0',
        'max' => '1000',
        'type' => 'leaf',
        'description' => 'Set the initial off-brightness 
This value is used when the display is normally
switched off in case LCDd is inactive'
      }
    ]
  }
]
;

