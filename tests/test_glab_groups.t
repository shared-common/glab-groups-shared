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
            lfs_enabled => JSON::PP::false,
        },
        undef,
        {
            force_lfs => JSON::PP::false,
        },
        undef,
    );
    is( $action, "create_project", "missing target repositories are created" );
}

{
    no warnings 'redefine';

    local *GlabGroups::_load_target_client = sub { return {}; };
    local *GlabGroups::_load_target_root_group_path = sub { return "owner"; };
    local *GlabGroups::_ensure_group_path = sub { return 42; };
    local *GlabGroups::_build_target_project_index = sub { return {}; };

    my $plan = GlabGroups::_build_plan(
        {
            defaults => { additional_branches => [], additional_tags => [], force_lfs => JSON::PP::false },
            exclusions => {},
            overrides => {},
        },
        {
            inventory => [
                {
                    group_path => "root",
                    namespace => {
                        target_namespace_path => "mirror",
                    },
                    projects => [
                        {
                            archived => JSON::PP::true,
                            default_branch => "main",
                            description => "source",
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://example.invalid/root/project.git",
                            id => 10,
                            lfs_enabled => JSON::PP::false,
                            path_with_namespace => "root/project",
                            ssh_url_to_repo => 'git@example.invalid:root/project.git',
                            visibility => "public",
                        },
                    ],
                },
            ],
        },
        25,
    );
    is( $plan->{plan}->[0]->{action}, "skip", "archived source projects are skipped during planning" );
    is( $plan->{plan}->[0]->{skip_reason}, "Archived source repository is excluded from mirroring.", "records the archived source skip reason" );
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
    my $result = GlabGroups::_mirror_entry(
        {},
        {},
        {
            action => "fail",
            target_full_path => "owner/group/project",
        },
    );
    is( $result->{status}, "skipped", "plan-level fail entries are downgraded to skipped mirrors" );
    is( $result->{reason}, "Repository skipped after plan error.", "records a skip reason for plan-level failures" );
}

{
    no warnings 'redefine';

    local *GlabGroups::_load_target_client = sub { return {}; };
    local *GlabGroups::_load_target_root_group_path = sub { return "owner"; };
    local *GlabGroups::_ensure_group_path = sub { return 42; };
    local *GlabGroups::_build_target_project_index = sub { return {}; };

    my $plan = GlabGroups::_build_plan(
        {
            defaults => { additional_branches => [], additional_tags => [], force_lfs => JSON::PP::false },
            exclusions => {},
            overrides => {},
        },
        {
            inventory => [
                {
                    group_path => "root",
                    namespace => {
                        target_namespace_path => "mirror",
                    },
                    projects => [
                        {
                            archived => JSON::PP::false,
                            default_branch => "main",
                            description => "source",
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://example.invalid/root/project.git",
                            id => 10,
                            lfs_enabled => JSON::PP::false,
                            path_with_namespace => "root/project",
                            ssh_url_to_repo => 'git@example.invalid:root/project.git',
                            visibility => "public",
                        },
                    ],
                },
            ],
        },
        25,
    );
    is( $plan->{plan}->[0]->{action}, "create_project", "missing target projects are planned for creation" );
    ok( !defined $plan->{plan}->[0]->{skip_reason}, "missing target projects do not get a skip reason" );
    is( $plan->{plan}->[0]->{target_namespace_id}, 42, "missing target projects keep resolved target namespace id for creation" );
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
    my $source = File::Spec->catdir( $dir, "source" );
    my $mirror = File::Spec->catdir( $dir, "mirror" );

    my ( $status, $output ) = run_cmd( "git", "init", "-b", "master", $source );
    is( $status, 0, "source git init succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $source, "config", "user.email", 'tests@example.invalid' );
    is( $status, 0, "source git config email succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $source, "config", "user.name", "Tests" );
    is( $status, 0, "source git config name succeeds" ) or diag($output);
    open( my $fh, ">:encoding(UTF-8)", File::Spec->catfile( $source, "README.md" ) ) or die "unable to write source file";
    print {$fh} "source\n";
    close $fh;
    ( $status, $output ) = run_cmd( "git", "-C", $source, "add", "README.md" );
    is( $status, 0, "source git add succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $source, "commit", "-m", "source" );
    is( $status, 0, "source git commit succeeds" ) or diag($output);

    ( $status, $output ) = run_cmd( "git", "init", $mirror );
    is( $status, 0, "mirror git init succeeds" ) or diag($output);
    ( $status, $output ) = run_cmd( "git", "-C", $mirror, "remote", "add", "source", $source );
    is( $status, 0, "mirror remote add succeeds" ) or diag($output);

    GlabGroups::_fetch_selected_refs(
        $mirror,
        { branches => ["master"], tags => [] },
        { git_timeout_seconds => 300, retry_attempts => 1, retry_backoff_seconds => 1 },
    );
    ( $status, $output ) = run_cmd( "git", "-C", $mirror, "rev-parse", "--verify", "refs/heads/master" );
    is( $status, 0, "fetch creates refs/heads/master without checked-out branch conflict" ) or diag($output);
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
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $output_path = File::Spec->catfile( $dir, "prepared.json" );
    my @prepared_paths;

    write_json_file(
        $plan_path,
        {
            plan => [
                {
                    action => "create_project",
                    target_full_path => "owner/group/project-a",
                },
                {
                    action => "skip",
                    target_full_path => "owner/group/project-b",
                },
            ],
        }
    );

    local *GlabGroups::_load_target_client = sub { return {}; };
    local *GlabGroups::_ensure_target_project = sub {
        my ( $client, $entry ) = @_;
        push @prepared_paths, $entry->{target_full_path};
        return { project_id => 99 };
    };

    is(
        GlabGroups::run_cli(
            "prepare-target",
            "--plan", $plan_path,
            "--output", $output_path,
        ),
        0,
        "prepare-target accepts create_project entries",
    );
    is_deeply(
        \@prepared_paths,
        [ "owner/group/project-a" ],
        "prepare-target prepares missing target projects",
    );
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
        return undef if $group_path eq "owner/freedesktop";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        if ( $method eq "POST" && $path eq "/groups" ) {
            die "gitlab request failed [400] POST /groups: {\"message\":\"Failed to save group {:path=>[\\\"has already been taken\\\"]}\"}\n";
        }
        if ( $method eq "GET" && $path eq "/groups/7/subgroups?per_page=100&page=1&search=freedesktop" ) {
            return [
                {
                    id => 84,
                    full_path => "owner/freedesktop",
                    path => "freedesktop",
                },
            ];
        }
        die "unexpected gitlab request: $method $path";
    };

    my $group_id = GlabGroups::_ensure_group_path( {}, "owner/freedesktop", \%cache );
    is( $group_id, 84, "reuses existing group after GitLab path array conflict payload" );
    is( $cache{"owner/freedesktop"}, 84, "caches resolved group id after array-style conflict lookup" );
}

{
    no warnings 'redefine';
    my %cache = (
        owner => 7,
        "owner/freedesktop" => 8,
    );

    local *GlabGroups::_get_group = sub {
        my ( $client, $group_path ) = @_;
        return undef if $group_path eq "owner/freedesktop/wlroots";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        if ( $method eq "POST" && $path eq "/groups" ) {
            die "gitlab request failed [400] POST /groups: {\"message\":\"Failed to save group {:path=>[\\\"has already been taken\\\"]}\"}\n";
        }
        if ( $method eq "GET" && $path eq "/groups/8/subgroups?per_page=100&page=1&search=wlroots" ) {
            return [];
        }
        if ( $method eq "GET" && $path eq "/groups/8/subgroups?per_page=100&page=1&all_available=true" ) {
            return [
                {
                    id => 99,
                    full_path => "owner/freedesktop/wlroots",
                    path => "wlroots",
                },
            ];
        }
        die "unexpected gitlab request: $method $path";
    };

    my $group_id = GlabGroups::_ensure_group_path( {}, "owner/freedesktop/wlroots", \%cache );
    is( $group_id, 99, "reuses existing nested group after search fallback misses it" );
    is( $cache{"owner/freedesktop/wlroots"}, 99, "caches nested group id after enumerating existing subgroups" );
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
        if ( $method eq "GET" && $path eq "/groups/7/subgroups?per_page=100&page=1&all_available=true" ) {
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
    my @requests;

    local *GlabGroups::_get_group = sub {
        my ( $client, $group_path ) = @_;
        return { id => 1, full_path => "root" } if $group_path eq "root";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, opt => $opt };
        return [
            { id => 101, path_with_namespace => "root/project-a" },
        ] if $method eq "GET" && $path eq "/groups/1/projects?include_subgroups=false&with_shared=false&per_page=50&page=1";
        return [
            { id => 2, full_path => "root/sub", path => "sub" },
        ] if $method eq "GET" && $path eq "/groups/1/subgroups?per_page=50&page=1";
        return [
            { id => 102, path_with_namespace => "root/sub/project-b" },
        ] if $method eq "GET" && $path eq "/groups/2/projects?include_subgroups=false&with_shared=false&per_page=50&page=1";
        return [] if $method eq "GET" && $path eq "/groups/2/subgroups?per_page=50&page=1";
        die "unexpected gitlab request: $method $path";
    };

    my $projects = GlabGroups::_list_group_projects(
        {},
        "root",
        {
            retry_attempts => 7,
            retry_backoff_seconds => 9,
        }
    );
    is_deeply(
        [ map { $_->{path_with_namespace} } @{$projects} ],
        [ "root/project-a", "root/sub/project-b" ],
        "lists direct group projects and recurses through subgroups",
    );
    ok(
        !( scalar grep { $_->{path} =~ /include_subgroups=true/ } @requests ),
        "group inventory no longer relies on include_subgroups project listing",
    );
    is( $requests[0]->{opt}->{retry_attempts}, 7, "group inventory forwards stronger read retry attempts" );
    is( $requests[0]->{opt}->{retry_backoff_seconds}, 9, "group inventory forwards stronger read retry backoff" );
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
    is( $requests[0]->{method}, "POST", "issues project creation API calls when target is missing" );
    is( $requests[0]->{path}, "/projects", "creates project through the GitLab projects API" );
    ok( !exists $requests[0]->{payload}->{visibility}, "project creation payload does not set visibility" );
}

{
    no warnings 'redefine';
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $output_path = File::Spec->catfile( $dir, "results.json" );
    my $jsonl_path = File::Spec->catfile( $dir, "results.jsonl" );

    write_json_file(
        $plan_path,
        {
            plan => [
                {
                    action => "create_project",
                    target_full_path => "owner/group/project-a",
                },
            ],
        }
    );

    local *GlabGroups::_load_target_client = sub { return {}; };
    local *GlabGroups::_load_source_auth = sub { return {}; };
    local *GlabGroups::_mirror_entry = sub {
        die "create project failed\n";
    };

    is(
        GlabGroups::run_cli(
            "mirror",
            "--plan", $plan_path,
            "--output", $output_path,
            "--jsonl", $jsonl_path,
        ),
        0,
        "mirror command completes and records create_project failures",
    );
    my $results = JSON::PP->new->decode( do { open( my $fh, "<:encoding(UTF-8)", $output_path ) or die $!; local $/; <$fh> } );
    is( $results->{results}->[0]->{status}, "failed", "unexpected mirror exceptions are reported as failed rows" );
    is( $results->{results}->[0]->{reason}, "Repository failed after unrecoverable mirror error.", "failed row keeps a clear error reason" );
}

{
    no warnings 'redefine';
    my @requests;

    local *GlabGroups::_get_project = sub {
        my ( $client, $project_path ) = @_;
        return { id => 99, description => "old", lfs_enabled => JSON::PP::false, archived => JSON::PP::false };
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return { id => 99, archived => JSON::PP::false, description => "source", lfs_enabled => JSON::PP::false };
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
    ok( !$result->{created}, "does not create when project already exists" );
    ok( $result->{updated}, "updates existing target project metadata when needed" );
    ok( !exists $requests[0]->{payload}->{visibility}, "project update payload does not set visibility" );

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

{
    no warnings 'redefine';
    my @requests;

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return { id => 99 };
    };

    GlabGroups::_ensure_target_lfs_enabled( {}, 99 );
    is( $requests[0]->{path}, "/projects/99", "enables target project LFS by project id" );
    ok( $requests[0]->{payload}->{lfs_enabled}, "sets lfs_enabled true for discovered LFS repositories" );
}

{
    my $sanitized = GlabGroups::_sanitize_payload(
        {
            error => "fatal: https://svc:glpat-secret123\@gitlab.com/group/repo.git and ghp_secretvalue",
            nested => [ "PRIVATE-TOKEN: glpat-other456" ],
        }
    );
    unlike( $sanitized->{error}, qr/glpat-secret123/, "redacts PAT from authenticated URL errors" );
    unlike( $sanitized->{error}, qr/ghp_secretvalue/, "redacts GitHub-style tokens from errors" );
    like( $sanitized->{error}, qr{https://<redacted>\@gitlab\.com/group/repo\.git}, "keeps redacted URL shape useful" );
    is( $sanitized->{nested}->[0], "PRIVATE-TOKEN: <redacted>", "redacts PRIVATE-TOKEN header values" );
}

done_testing();
