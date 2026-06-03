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
    is( $config->{defaults}->{batch_size}, 25, "keeps default batch size at 25" );
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
            force_lfs => JSON::PP::true,
        },
        undef,
    );
    is( $action, "update_project", "detects non-visibility metadata drift" );
}

{
    my $policy = GlabGroups::_merge_policy(
        {
            additional_branches => [],
            additional_tags => [],
            force_lfs => JSON::PP::false,
        },
        {
            additional_branches => [],
            additional_tags => [],
        },
        {
            additional_branches => [],
            additional_tags => [],
        },
    );
    ok( !exists $policy->{visibility}, "merge policy does not carry target visibility" );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    write_json_file(
        File::Spec->catfile( $dir, "defaults.json" ),
        {
            kind => "glab-groups/defaults",
            version => 1,
            defaults => {
                visibility => "private",
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
    my $loaded = eval {
        load_config_dir($dir);
        1;
    };
    ok( !$loaded, "rejects removed visibility config" );
    like( $@, qr/visibility is no longer supported/, "reports removed visibility contract" );
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

{
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $results_0 = File::Spec->catfile( $dir, "results-0.json" );
    my $results_1 = File::Spec->catfile( $dir, "results-1.json" );
    my $report_path = File::Spec->catfile( $dir, "report.json" );
    my $summary_path = File::Spec->catfile( $dir, "report.md" );
    write_json_file(
        $plan_path,
        {
            counts => { create_project => 1, fail => 0, mirror_only => 1, skip => 0, update_project => 0 },
        }
    );
    write_json_file(
        $results_0,
        {
            results => [
                {
                    target_full_path => "owner/debian/demo",
                    planned_action => "create_project",
                    status => "mirrored",
                },
            ],
        }
    );
    write_json_file(
        $results_1,
        {
            results => [
                {
                    target_full_path => "owner/kali/demo",
                    planned_action => "mirror_only",
                    reason => "Repository above permitted size limit.",
                    status => "skipped",
                },
            ],
        }
    );

    is(
        GlabGroups::run_cli(
            "report",
            "--plan", $plan_path,
            "--results", $results_0,
            "--results", $results_1,
            "--output", $report_path,
            "--summary", $summary_path,
        ),
        0,
        "report merges multiple batch result files",
    );
    my $report = JSON::PP->new->decode( do { open( my $fh, "<:encoding(UTF-8)", $report_path ) or die $!; local $/; <$fh> } );
    is( scalar @{ $report->{results} }, 2, "merged report preserves all batch rows" );
    is( $report->{result_counts}->{mirrored}, 1, "merged report counts mirrored rows" );
    is( $report->{result_counts}->{skipped}, 1, "merged report counts skipped rows" );
}

{
    no warnings 'redefine';
    my %cache = ( owner => 7 );

    local *GlabGroups::_get_group = sub {
        my ( $client, $group_path ) = @_;
        return undef if $group_path eq "owner/MixedCase-team";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        if ( $method eq "POST" && $path eq "/groups" ) {
            die "gitlab request failed [400] POST /groups: {\"message\":\"Failed to save group {:base=>[\\\"path has already been taken\\\"]}\"}\n";
        }
        if ( $method eq "GET" && $path eq "/groups/7/subgroups?per_page=100&page=1&search=MixedCase-team" ) {
            return [
                {
                    id => 42,
                    full_path => "owner/MixedCase-team",
                    path => "MixedCase-team",
                },
            ];
        }
        die "unexpected gitlab request: $method $path";
    };

    my $group_id = GlabGroups::_ensure_group_path( {}, "owner/MixedCase-team", \%cache );
    is( $group_id, 42, "reuses existing group after path conflict" );
    is( $cache{"owner/MixedCase-team"}, 42, "caches resolved group id after conflict lookup" );
}

{
    no warnings 'redefine';
    my %cache = ( owner => 7 );

    local *GlabGroups::_get_group = sub {
        my ( $client, $group_path ) = @_;
        return undef if $group_path eq "owner/Missing-team";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        if ( $method eq "POST" && $path eq "/groups" ) {
            die "gitlab request failed [400] POST /groups: {\"message\":\"Failed to save group {:base=>[\\\"path has already been taken\\\"]}\"}\n";
        }
        if ( $method eq "GET" && $path eq "/groups/7/subgroups?per_page=100&page=1&search=Missing-team" ) {
            return [];
        }
        die "unexpected gitlab request: $method $path";
    };

    my $error = eval {
        GlabGroups::_ensure_group_path( {}, "owner/Missing-team", \%cache );
        1;
    };
    ok( !$error, "conflict without resolvable group still fails" );
    like( $@, qr/gitlab group path conflict for owner\/Missing-team:/, "reports the unresolved group path in the conflict error" );
    like( $@, qr/path has already been taken/i, "preserves the original GitLab path conflict detail" );
}

{
    no warnings 'redefine';
    my %cache;
    my @payloads;

    local *GlabGroups::_get_group = sub {
        my ( $client, $group_path ) = @_;
        return undef if $group_path eq "owner";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        if ( $method eq "POST" && $path eq "/groups" ) {
            push @payloads, $payload;
            return { id => 7 };
        }
        die "unexpected gitlab request: $method $path";
    };

    my $group_id = GlabGroups::_ensure_group_path( {}, "owner", \%cache );
    is( $group_id, 7, "creates missing group" );
    ok( !exists $payloads[0]->{visibility}, "group creation payload does not set visibility" );
}

{
    no warnings 'redefine';
    my @requests;

    local *GlabGroups::_get_project = sub {
        my ( $client, $project_path ) = @_;
        return undef;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return { id => 99, archived => JSON::PP::false };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "source",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "owner/group/project",
            target_namespace_id => 42,
        }
    );
    ok( $result->{created}, "creates missing target project" );
    ok( !exists $requests[0]->{payload}->{visibility}, "project creation payload does not set visibility" );

    GlabGroups::_finalize_target_project(
        {},
        99,
        "main",
        {
            source_description => "source",
        }
    );
    ok( !exists $requests[1]->{payload}->{visibility}, "project finalize payload does not set visibility" );
}

done_testing();
