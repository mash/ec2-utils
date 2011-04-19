#!/usr/bin/env perl
use strict;
use warnings;
use Config::Pit;
use Net::Amazon::EC2;
use DateTime;
use DateTime::Format::ISO8601;
use Getopt::Long;

my ($pit, $region, $volume, $description, $account, $generations);
$region = 'us-west-1';
GetOptions ( "pit|p=s"          => \$pit,
             "region|r:s"       => \$region,
             "volume|v=s"       => \$volume,
             "description|d=s"  => \$description,
             "account|a=s"      => \$account,
             "generations|g=i"  => \$generations,
         )
    or die usage();

my $config = pit_get( $pit, require => {
    AWSAccessKeyId  => 'access key id',
    SecretAccessKey => 'secret access key',
});

my $ec2 = Net::Amazon::EC2->new(
    AWSAccessKeyId  => $config->{AWSAccessKeyId},
    SecretAccessKey => $config->{SecretAccessKey},
    region          => $region,
);

my $snapshot = $ec2->create_snapshot( VolumeId => $volume, Description => $description );
print "started snapshot: ". $snapshot->snapshot_id . "\n";

#my $snapshots = $ec2->describe_snapshots;
#my @same_type_snapshots = grep { 1; } @$snapshots;
my $snapshots = $ec2->describe_snapshots( Owner => $account );
my @same_type_snapshots = grep { $_->description eq $description; } @$snapshots;
print @same_type_snapshots . " generations found for '$description'\n";
exit if ( scalar @same_type_snapshots <= $generations );

# delete old snapshots
my @sorted_snapshots = sort {
    DateTime::Format::ISO8601->parse_datetime($a->start_time)->epoch <=> DateTime::Format::ISO8601->parse_datetime($b->start_time)->epoch
} @same_type_snapshots;
while ( my $old_snapshot = shift @sorted_snapshots ) {
    print "deleting snapshot: " . $old_snapshot->snapshot_id . "\n";
    $ec2->delete_snapshot( SnapshotId => $old_snapshot->snapshot_id );
    last if scalar( @sorted_snapshots ) <= $generations;
}

sub usage {
    "usage: $0 -p <pit_key> -r 'us-west-1' -v <vol-********> -d <description:String> -a <accountnumber:String> -g <generations:Int>";
}
