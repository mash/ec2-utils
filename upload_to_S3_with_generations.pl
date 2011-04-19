#!/usr/bin/env perl
use strict;
use warnings;
use Config::Pit;
use Amazon::S3;
use DateTime;
use DateTime::Format::ISO8601;
use Path::Class;
use Getopt::Long;

my ($pit, $bucket_name, $generations);
GetOptions ( "pit|p=s"          => \$pit,
             "bucket|b=s",      => \$bucket_name,
             "generations|g=i"  => \$generations,
         )
    or die usage();

my $filename = shift @ARGV
    or die usage();

my $file = file( $filename );
die "$filename not found" unless -e $file;

my $config = pit_get( $pit, require => {
    AWSAccessKeyId  => 'access key id',
    SecretAccessKey => 'secret access key',
});

my $s3 = Amazon::S3->new({
    aws_access_key_id     => $config->{AWSAccessKeyId},
    aws_secret_access_key => $config->{SecretAccessKey},
});

my $buckets = $s3->buckets->{ buckets };
my ($bucket) = grep { $_->bucket eq $bucket_name } @{ $buckets };

# upload
$bucket->add_key_filename( $file->basename, $filename );
print "uploaded: $filename\n";

my $keys = $bucket->list->{ keys };
exit if ( scalar @$keys <= $generations );

# delete old snapshots
my @sorted_keys = sort {
    DateTime::Format::ISO8601->parse_datetime($a->{last_modified})->epoch <=> DateTime::Format::ISO8601->parse_datetime($b->{last_modified})->epoch;
} @$keys;
while ( my $old_key = shift @sorted_keys ) {
    print "deleting key: $old_key->{ key }\n";
    $bucket->delete_key( $old_key->{ key } );
    last if scalar( @sorted_keys ) <= $generations;
}

sub usage {
    "usage: $0 -p <pit_key> -b <bucket_name:String> -g <generations:Int> <filename>";
}
