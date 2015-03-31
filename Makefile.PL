use inc::Module::Install;

# Define metadata
name           'YAHC';
all_from       'lib/YAHC.pm';
license        'perl';

# Specific dependencies
requires       'EV'                                 => '0';
requires       'POSIX'                              => '0';
requires       'Scalar::Util'                       => '0';
requires       'Time::HiRes'                        => '0';

#test_requires  'Test::More'     => '0.88';

WriteAll;
