unit module Config;

sub config is export {
  {
    listen-ip   => '127.0.0.1',
    listen-port => 8666,
    gh-secret   => 'secret',
    gh-client   => 'client',
  };
}
