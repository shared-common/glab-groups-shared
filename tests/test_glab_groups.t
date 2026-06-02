use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use JSON::PP;
use Test::More;

use lib File::Spec->catdir( $Bin, "..", "lib" );

use GlabGroups qw(
  analyze_selected_refs
  classify_plan_action
  load_config_dir
  resolve_selected_refs
);

my $json = JSON::PP->new->canonical(1)->utf8(1)->pretty(1);

sub write_json_file {
    my ( $path, $payload ) = @_;
    open( my $fh, ">:encoding(UTF-8)", $path ) or die "unable to write $path";
    print {$fh} $json->encode($payload);
    close $fh;
}

sub run_cmd {
    my (@args) = @_;
    my $cmd = join q{ }, map { "'" . ( my $v = $_ ) =~ s/'/'"'"'/gr . "'" } @args;
    my $output = qx{$cmd 2>&1};
    my $status = $? >> 8;
    return ( $status, $output );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    write_json_file(
        File::Spec->catfile( $dir, "defaults.json" ),
        {
            kind => "glab-groups/defaults",
            version => 1,
            defaults => {
                additional_branches => ["release"],
                mirror_pristine_tar => JSON::PP::true,
            },
        }
    );
    write_json_file(
        File::Spec->catfile( $dir, "namespaces.json" ),
        {
            kind => "glab-groups/namespaces",
            version => 1,
            namespaces => [
                {
                    name => "kali",
                    source_group_url => "https://gitlab.com/kalilinux",
                    target_namespace_path => "kalilinux",
                },
            ],
        }
    );
    my $config = load_config_dir($dir);
    is( scalar @{ $config->{namespaces} }, 1, "loads namespace roots" );
    is( $config->{defaults}->{additional_branches}->[0]->{name}, "release", "normalizes default branches" );
}

{
    my $refs = resolve_selected_refs(
        "main",
        {
            additional_branches => [ { name => "upstream" } ],
            additional_tags => [ { name => "v1.0.0" } ],
            mirror_pristine_tar => JSON::PP::true,
        },
        {
            branches => { main => 1, "pristine-tar" => 1, upstream => 1 },
            tags => { "pristine-tar" => 1, "v1.0.0" => 1 },
        },
    );
    is_deeply(
        $refs,
        {
            branches => [ "main", "pristine-tar", "upstream" ],
            tags => [ "pristine-tar", "v1.0.0" ],
        },
        "resolves default, pristine-tar, and configured refs",
    );
}

{
    my $action = classify_plan_action(
        {
            visibility => "public",
            description => "source",
            archived => JSON::PP::false,
            lfs_enabled => JSON::PP::true,
        },
        {
            visibility => "private",
            description => "target",
            archived => JSON::PP::false,
            lfs_enabled => JSON::PP::false,
        },
        {
            visibility => "public",
            force_lfs => JSON::PP::true,
        },
        undef,
    );
    is( $action, "update_project", "detects metadata drift" );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    my $blob_path = File::Spec->catfile( $dir, "blob.bin" );
    open( my $blob, ">:raw", $blob_path ) or die "unable to write blob";
    print {$blob} "a" x ( 1024 * 1024 + 13 );
    close $blob;

    my ( $status, $output ) = run_cmd( "git", "init", "-b", "main", $dir );
    is( $status, 0, "git init succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $dir, "config", "user.email", 'tests@example.invalid' );
    is( $status, 0, "git config email succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $dir, "config", "user.name", "Tests" );
    is( $status, 0, "git config name succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $dir, "add", "blob.bin" );
    is( $status, 0, "git add succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $dir, "commit", "-m", "blob" );
    is( $status, 0, "git commit succeeds" ) or diag($output);

    my $analysis = analyze_selected_refs(
        $dir,
        { branches => ["main"], tags => [] },
        64,
    );
    cmp_ok( $analysis->{total_bytes}, ">", 1024 * 1024, "counts selected object bytes" );
    is( scalar @{ $analysis->{oversized_blobs} }, 1, "detects oversize blob" );
}

done_testing();
