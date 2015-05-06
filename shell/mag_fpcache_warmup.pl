#!/usr/bin/perl -w

=head1 mag_fpcache_warmup.pl

The script performs full page cache warm-up for magento-based site. It works in multithreaded mode to allow faster completion time but consuming more server resources. 

=head2 configuration params 

(see CONFIG section in the script itself)

=over

=item threads_num - number of parallel threads of execution to use. It's generally safe to use half number of CPU cores in dedicated hardware server where magento is installed. 

=item db_config_xml - path to magento configuration file where database connection params are retrieved from (<magento_root>/app/etc/local.xml).

=item base_url - constant part of URLs used in polling (like 'http://www.magento-shop.com'). The script reads it from magento database, but it can also be overridden in the script itself.

=back

=head2 author

Victor Ichalov <ichalov@gmail.com>

=cut

use strict;
use warnings;

## kill any other warm-up scripts currently executing to prevent server overload
use File::Basename;

my $script_name = basename($0);
my $res = `ps aux | grep '$script_name'`;

for my $str (split "\n", $res) {
  if ($str =~ m!perl\s+$script_name\s*!) {
    if ($str =~ m!^[\w-]+\s+(\d+)! ) {
      my $pid = $1;
      if ($pid ne $$) {
        `kill -9 $pid`;
      }
    }
  }
}
##

use DBI;
use LWP::UserAgent;
use POSIX qw/strftime/;
use Time::HiRes qw/gettimeofday/;

use threads;
use threads::shared;
use Thread::Semaphore;

use HTTP::Tiny;

################# CONFIG

my $threads_num = 4;
my $db_config_xml = dirname($0)."/../app/etc/local.xml"; # the script is supposed to be in <magento_root>/shell dir
my $base_url = "http://localhost";

################# LOAD DB CONFIG

my %config = ();

my %config_transform = (
  'host' => 'db.host',
  'username' => 'db.login',
  'password' => 'db.password',
  'dbname' => 'db.db',
);

open my $f, "<", $db_config_xml 
  or die "Can't open DB config file : $db_config_xml";
my $xml = "";
{
  local $/ = undef;
  $xml = <$f>;
};
close $f;

if ($xml =~ m!<connection>(.*)<active>1</active>(.*)</connection>!ims) {
  my $conn_elem = $1.$2;
  for my $elem (keys %config_transform) {
    if ($conn_elem =~ m#<$elem>(?:<!\[CDATA\[)(.+?)(?:\]\]>)</$elem>#ims) {
      $config{$config_transform{$elem}} = $1;
    }
    else {
      die "Can't find $elem element in active connection in $db_config_xml";
    }
  }
}
else {
  die "Can't find active connection element in $db_config_xml";
}

################# INITIALIZATION
my $db = DBI->connect("DBI:mysql:$config{'db.db'};host=$config{'db.host'}", 
    $config{'db.login'}, $config{'db.password'})
  or die "Couldn't connect to the database : $@";
$db->do('set character_set_client = utf8');
#$db->do('set names utf8');

$base_url = shift @{$db->selectcol_arrayref("select value from core_config_data where path = 'web/unsecure/base_url' and scope_id = 0")} || $base_url;
$base_url =~ s!/$!!;

################# CONSTANTS

my @urls = (
  $base_url."/",
);

################# MAIN

### Pupulate URL list

# Categories
my $sth = $db->prepare("select r.* from core_url_rewrite as r left join catalog_category_entity as e on (r.category_id = e.entity_id) where id_path like 'category/%' order by e.level, r.category_id");
$sth->execute;
my @add_urls = ();
while (my $rs = $sth->fetchrow_hashref) {
  push @urls, $base_url."/".$rs->{request_path};
#  push @add_urls, $base_url."/".$rs->{request_path}."?mode=list";
}
@urls = (@urls, @add_urls);

# Products
$sth = $db->prepare("select * from core_url_rewrite where id_path like 'product/%'");
$sth->execute;
while (my $rs = $sth->fetchrow_hashref) {
  next if ($rs->{id_path} !~ m!^product/\d+$!);
  push @urls, $base_url."/".$rs->{request_path};
}

### Measure response times

my %failed_urls :shared = ();
my %response_times :shared = ();
my $shared_storage_lock :shared;
my $s = Thread::Semaphore->new($threads_num);
for my $url (@urls) {
  my $http = HTTP::Tiny->new;

  $s->down();
  my $t = threads->create( sub {
    my $start = microtime(); 
#    my $ua = new LWP::UserAgent;
#    $ua->agent('mag_fpcache_warmup/1.0');
#    my $resp = $ua->get($url);
#    my $cont = $resp->decoded_content;
    my $resp = $http->get($url) or warn "$!";
    my $cont = $resp->{'content'} || "";

    lock($shared_storage_lock);
    $response_times{$url} = (microtime() - $start) || 0;
    print strftime("%Y%m%d%H%M%S", localtime)." $url ".$resp->{status}." ".$response_times{$url}."\n";
#    print strftime("%Y%m%d%H%M%S", localtime)." $url ".$resp->status_line." ".$response_times{$url}."\n";
#    if ($resp->status_line !~ m!200!) {
    if ($resp->{status} !~ m!200!) {
      $failed_urls{$url} = $resp->{status};
    }
    $s->up();
    threads->detach();
  });

}

my $thread_wait_cnt = 0;
my $thread_wait_seconds = 60;
while (threads->list(threads::all)) {
  sleep(1);
  if (++$thread_wait_cnt > $thread_wait_seconds) {
    last;
  }
}

=begin comment
### Print report

my $fu = "\nFailed URLs:\n\n";
for my $url (keys %failed_urls) {
  $fu .= "$url : ".$failed_urls{$url}." : ".$response_times{$url}."\n";
  delete($response_times{$url});
}
print "Response Times:\n\n";
for my $url (reverse sort {$response_times{$a} <=> $response_times{$b}} keys %response_times) {
  print "$url : ".$response_times{$url}."\n";
}
print $fu;
=end comment
=cut

################# FUNCTIONS

sub microtime{
  my $asFloat = 1;
  if(@_){
    $asFloat = shift;
  }
  (my $epochseconds, my $microseconds) = gettimeofday;
  my $microtime;
  if($asFloat){
    while(length("$microseconds") < 6){
      $microseconds = "0$microseconds";
    }
    $microtime = "$epochseconds.$microseconds";
  } else {
    $microtime = "$epochseconds $microseconds";
  }
  return $microtime;
}
