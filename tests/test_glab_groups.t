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

sub write_text_file {
    my ( $path, $text ) = @_;
    open( my $fh, ">:encoding(UTF-8)", $path ) or die "unable to write $path";
    print {$fh} $text;
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
                target_branches_protect => ["gitlab/mcr/main"],
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
                    target_branches_protect => ["gitlab/mcr/main"],
                    target_owner_path => "glab-forks",
                    target_namespace_path => "kalilinux",
                },
            ],
        }
    );
    my $config = load_config_dir($dir);
    is( scalar @{ $config->{namespaces} }, 1, "loads namespace roots" );
    is( $config->{defaults}->{additional_branches}->[0]->{name}, "release", "normalizes default branches" );
    is( $config->{defaults}->{target_branches_protect}->[0]->{name}, "gitlab/mcr/main", "normalizes default protected target branches" );
    is( $config->{defaults}->{batch_size}, 10, "keeps default batch size at 10" );
    is( $config->{defaults}->{max_parallel}, 5, "keeps default max parallel at 5" );
    is( $config->{namespaces}->[0]->{target_branches_protect}->[0]->{name}, "gitlab/mcr/main", "loads namespace protected target branches" );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    write_json_file(
        File::Spec->catfile( $dir, "defaults.json" ),
        {
            kind => "glab-groups/defaults",
            version => 1,
            defaults => {},
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
                    target_owner_path => "glab-forks",
                    target_namespace_path => "kalilinux",
                },
            ],
        }
    );
    my $config = load_config_dir($dir);
    is( $config->{namespaces}->[0]->{target_owner_path}, "glab-forks", "loads target owner path from namespace entries" );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    write_json_file(
        File::Spec->catfile( $dir, "defaults.json" ),
        {
            kind => "glab-groups/defaults",
            version => 1,
            defaults => {
                max_parallel => 6,
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
                    target_owner_path => "glab-forks",
                    target_namespace_path => "kalilinux",
                },
            ],
        }
    );

    my $error = eval { load_config_dir($dir); 1 } ? undef : $@;
    like( $error, qr/defaults\.json\.defaults\.max_parallel must be less than or equal to 5/, "rejects max_parallel values above the workflow contract" );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    write_text_file(
        File::Spec->catfile( $dir, "defaults.yml" ),
        <<'YAML'
kind: glab-groups/defaults
version: 1
defaults:
  additional_branches:
    - release
  additional_tags:
    - v1.0.0
  mirror_pristine_tar: true
  target_branches_protect:
    - gitlab/mcr/main
YAML
    );
    write_text_file(
        File::Spec->catfile( $dir, "projects.yml" ),
        <<'YAML'
kind: glab-groups/projects
version: 1
projects:
  - name: darkman
    source_project_url: https://gitlab.com/WhyNotHugo/darkman
    target_group_path: glab-forks/labwc
    additional_branches:
      - stable
    additional_tags:
      - v2.0.0
    target_branches_protect:
      - gitlab/mcr/main
YAML
    );

    my $config = load_config_dir($dir);
    is( scalar @{ $config->{projects} }, 1, "loads explicit projects from YAML config" );
    is( $config->{projects}->[0]->{target_group_path}, "glab-forks/labwc", "keeps the full explicit target group path" );
    is( $config->{defaults}->{additional_branches}->[0]->{name}, "release", "loads default branches from YAML config" );
    is( $config->{projects}->[0]->{additional_branches}->[0]->{name}, "stable", "loads per-project branch overrides from YAML config" );
    is( $config->{projects}->[0]->{target_branches_protect}->[0]->{name}, "gitlab/mcr/main", "loads per-project protected target branches from YAML config" );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    write_text_file(
        File::Spec->catfile( $dir, "defaults.yml" ),
        <<'YAML'
kind: glab-groups/defaults
version: 1
defaults:
  additional_branches: []
  additional_tags: []
YAML
    );
    write_text_file(
        File::Spec->catfile( $dir, "projects.yml" ),
        <<'YAML'
- name: poweralertd
  source_project_url: https://git.sr.ht/~kennylevinsen/poweralertd
  target_group_path: glab-forks/labwc
  additional_branches:
    - debian/sid
    - debian/experimental
  additional_tags: []
  target_branches_protect:
    - gitlab/mcr/main
    - mcr/main
YAML
    );

    my $config = load_config_dir($dir);
    is( scalar @{ $config->{projects} }, 1, "loads explicit projects from a bare projects.yml list" );
    is( $config->{projects}->[0]->{name}, "poweralertd", "keeps the explicit project name from bare projects.yml" );
    is( $config->{projects}->[0]->{additional_branches}->[1]->{name}, "debian/experimental", "loads branch overrides from bare projects.yml" );
    is(
        $config->{projects}->[0]->{target_branches_protect}->[1]->{name},
        "mcr/main",
        "loads protected branch overrides from bare projects.yml",
    );
}

{
    my $dir = tempdir( CLEANUP => 1 );
    write_json_file(
        File::Spec->catfile( $dir, "defaults.json" ),
        {
            kind => "glab-groups/defaults",
            version => 1,
            defaults => {},
        }
    );
    write_json_file(
        File::Spec->catfile( $dir, "namespaces.json" ),
        {
            kind => "glab-groups/namespaces",
            version => 1,
            namespaces => [
                {
                    name => "labwc",
                    source_group_url => "https://github.com/labwc",
                    target_owner_path => "glab-forks",
                    target_namespace_path => "labwc",
                },
            ],
        }
    );
    write_text_file(
        File::Spec->catfile( $dir, "projects.yml" ),
        <<'YAML'
[]
YAML
    );

    my $config = load_config_dir($dir);
    is( scalar @{ $config->{projects} }, 0, "accepts an empty optional projects.yml list" );
    is( scalar @{ $config->{namespaces} }, 1, "keeps namespace discovery when projects.yml is empty" );
}

{
    my $policy = GlabGroups::_merge_policy(
        {
            additional_branches => [],
            additional_tags => [],
            target_branches_protect => [ { name => "gitlab/mcr/main" } ],
        },
        {
            target_branches_protect => [ { name => "mcr/feature/init" } ],
        },
        {
            target_branches_protect => [ { name => "mcr/feature/init" } ],
        },
    );

    is_deeply(
        [ map { $_->{name} } @{ $policy->{target_branches_protect} } ],
        [ "gitlab/mcr/main", "mcr/feature/init", "mcr/feature/init" ],
        "merge policy carries configured protected target branches into the runtime policy",
    );
}

{
    my $config = {
        defaults => {
            additional_branches => [],
            additional_tags => [],
        },
        namespaces => [],
        exclusions => {},
    };
    my $inventory = {
        inventory => [
            {
                group_id => 1,
                group_path => "root",
                namespace => {
                    name => "root",
                    source_group_url => "https://gitlab.example.invalid/root",
                    target_owner_path => "glab-forks",
                    target_namespace_path => "mirror",
                },
                projects => [
                    map {
                        {
                            archived => JSON::PP::false,
                            default_branch => "main",
                            description => "source",
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://example.invalid/root/sub$_->{group}/project-$_->{id}.git",
                            id => $_->{id},
                            lfs_enabled => JSON::PP::false,
                            path_with_namespace => "root/sub$_->{group}/project-$_->{id}",
                            ssh_url_to_repo => "git\@example.invalid:root/sub$_->{group}/project-$_->{id}.git",
                            visibility => "public",
                        }
                    } (
                        { group => "1", id => 1 },
                        { group => "2", id => 2 },
                        { group => "3", id => 3 },
                        { group => "4", id => 4 },
                        { group => "5", id => 5 },
                        { group => "6", id => 6 },
                    ),
                ],
            },
        ],
    };

    my $plan = GlabGroups::_build_plan(
        $config,
        $inventory,
        1,
        {
            max_batches => 2,
        },
    );
    is( $plan->{batch_size}, 3, "plan raises batch size when needed to stay within max_batches" );
    is( $plan->{total_batches}, 2, "plan keeps the total batch count within max_batches" );
    is( $plan->{max_batches}, 2, "plan records the configured max_batches limit" );
}

{
    no warnings 'redefine';
    my @seen_source_urls;
    my @seen_github_auth_requests;

    local *GlabGroups::_load_source_auth = sub {
        return {
            github_app => { app_id => "123", pem => "unused" },
            github_installation_tokens => {},
        };
    };
    local *GlabGroups::_github_installation_source_auth = sub {
        my ( $source_auth, $base_url, $account, $policy ) = @_;
        push @seen_github_auth_requests, [ $base_url, $account ];
        return { token => "ghs_install_token", username => "x-access-token" };
    };
    local *GlabGroups::_discover_remote_refs = sub {
        my ( $source_url, $policy ) = @_;
        push @seen_source_urls, $source_url;
        return {
            branches => { main => 1 },
            default_branch => "main",
            tags => {},
        };
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [],
            projects => [
                {
                    name => "gpt-oss",
                    source_project_url => "https://github.com/openai/gpt-oss",
                    target_group_path => "glab-forks/openai",
                },
            ],
        }
    );

    is_deeply(
        \@seen_github_auth_requests,
        [
            [ "https://github.com", "openai" ],
        ],
        "explicit GitHub project discovery resolves GitHub App auth for the source owner",
    );
    is(
        $inventory->{inventory}->[0]->{source_auth_mode},
        "github_app",
        "explicit GitHub project discovery marks the bucket for GitHub App source auth",
    );
    like(
        $seen_source_urls[0],
        qr{\Ahttps://x-access-token:ghs_install_token\@github\.com/openai/gpt-oss\.git\z},
        "explicit GitHub project discovery probes the remote with the installation token",
    );
    is(
        $inventory->{inventory}->[0]->{projects}->[0]->{http_url_to_repo},
        "https://github.com/openai/gpt-oss.git",
        "explicit GitHub project discovery strips credentials from the stored clone URL",
    );
}

{
    no warnings 'redefine';

    local *GlabGroups::_load_source_auth = sub {
        return {
            github_app => { app_id => "123", pem => "unused" },
            github_installation_tokens => {},
        };
    };
    local *GlabGroups::_github_installation_source_auth = sub {
        return { token => "ghs_install_token", username => "x-access-token" };
    };
    local *GlabGroups::_list_github_org_projects = sub {
        return [
            {
                archived => JSON::PP::false,
                clone_url => "https://github.com/openai/gpt-oss.git",
                default_branch => "main",
                description => "authoritative",
                full_name => "openai/gpt-oss",
                id => 101,
                path_with_namespace => "openai/gpt-oss",
                private => JSON::PP::false,
                pushed_at => "2026-06-10T00:00:00Z",
                size => 1,
                ssh_url => 'git@github.com:openai/gpt-oss.git',
                visibility => "public",
            },
            {
                archived => JSON::PP::false,
                clone_url => "https://github.com/openai/openai-agents-python.git",
                default_branch => "main",
                description => "namespace only",
                full_name => "openai/openai-agents-python",
                id => 102,
                path_with_namespace => "openai/openai-agents-python",
                private => JSON::PP::false,
                pushed_at => "2026-06-10T00:00:00Z",
                size => 1,
                ssh_url => 'git@github.com:openai/openai-agents-python.git',
                visibility => "public",
            },
        ];
    };
    local *GlabGroups::_discover_remote_refs = sub {
        return {
            branches => { main => 1, release => 1 },
            default_branch => "main",
            tags => {},
        };
    };

    my $config = {
        defaults => {
            additional_branches => [],
            additional_tags => [],
            force_lfs => JSON::PP::false,
        },
        namespaces => [
            {
                name => "openai-root",
                source_group_url => "https://github.com/openai",
                target_owner_path => "glab-forks",
                target_namespace_path => "openai",
                target_branches_protect => [ { name => "gitlab/mcr/main" } ],
            },
        ],
        projects => [
            {
                name => "gpt-oss",
                source_project_url => "https://github.com/openai/gpt-oss",
                target_group_path => "glab-forks/openai",
                force_lfs => JSON::PP::true,
                git_timeout_seconds => 900,
            },
        ],
        exclusions => {},
    };

    my $inventory = GlabGroups::_discover_inventory($config);
    is( scalar @{ $inventory->{inventory} }, 2, "keeps one namespace bucket plus one authoritative explicit project bucket" );
    is_deeply(
        [ map { $_->{path_with_namespace} } @{ $inventory->{inventory}->[0]->{projects} } ],
        ["openai/openai-agents-python"],
        "namespace discovery skips projects governed by authoritative projects.yml entries",
    );
    ok(
        ref( $inventory->{inventory}->[1]->{namespace} ) eq "HASH",
        "authoritative explicit project discovery keeps the matched namespace policy context",
    );

    my $plan = GlabGroups::_build_plan( $config, $inventory, 25 );
    is(
        $plan->{plan}->[0]->{target_relative_project_path},
        "openai/gpt-oss",
        "authoritative explicit project planning uses the namespace-relative target path",
    );
    ok(
        $plan->{plan}->[0]->{policy}->{force_lfs},
        "authoritative explicit project planning keeps explicit per-project boolean overrides",
    );
    is(
        $plan->{plan}->[0]->{policy}->{git_timeout_seconds},
        900,
        "authoritative explicit project planning keeps explicit per-project scalar overrides",
    );
    is_deeply(
        [ map { $_->{name} } @{ $plan->{plan}->[0]->{policy}->{target_branches_protect} } ],
        ["gitlab/mcr/main"],
        "authoritative explicit project planning inherits namespace branch protection",
    );
}

{
    no warnings 'redefine';

    local *GlabGroups::_load_source_auth = sub { return { github_app => { app_id => "123", pem => "unused" }, github_installation_tokens => {} }; };
    local *GlabGroups::_github_installation_source_auth = sub {
        my ( $source_auth, $base_url, $account, $policy ) = @_;
        return { token => "ghs_install_token", username => "x-access-token" };
    };
    local *GlabGroups::_github_request = sub {
        my ( $base_url, $path, $payload, $opt ) = @_;
        is( $opt->{auth_bearer}, "ghs_install_token", "GitHub org discovery uses the installation token as a bearer token" );
        return [
            {
                archived => JSON::PP::false,
                clone_url => "https://github.com/labwc/labwc.git",
                default_branch => "master",
                description => "Wayland compositor",
                full_name => "labwc/labwc",
                id => 101,
                private => JSON::PP::false,
                pushed_at => "2026-06-08T00:00:00Z",
                size => 128,
                ssh_url => 'git@github.com:labwc/labwc.git',
                visibility => "public",
            },
        ] if $path =~ /page=1/;
        return [] if $path =~ /page=2/;
        die "unexpected GitHub request: $base_url $path";
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [
                {
                    name => "labwc",
                    source_group_url => "https://github.com/labwc",
                    target_namespace_path => "labwc",
                },
            ],
        }
    );

    is( $inventory->{inventory}->[0]->{group_path}, "labwc", "GitHub org discovery keeps the org path as the source group path" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{path_with_namespace}, "labwc/labwc", "GitHub org discovery maps full_name into path_with_namespace" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{http_url_to_repo}, "https://github.com/labwc/labwc.git", "GitHub org discovery keeps the clone URL" );
}

{
    no warnings 'redefine';

    local *GlabGroups::_load_source_auth = sub { return { github_app => { app_id => "123", pem => "unused" }, github_installation_tokens => {} }; };
    local *GlabGroups::_github_installation_source_auth = sub {
        return { token => "ghs_install_token", username => "x-access-token" };
    };
    local *GlabGroups::_github_request = sub {
        my ( $base_url, $path, $payload, $opt ) = @_;
        return [
            {
                archived => JSON::PP::false,
                clone_url => "https://github.com/crowdsecurity/.github.git",
                default_branch => "main",
                description => "Community health files",
                full_name => "crowdsecurity/.github",
                id => 102,
                private => JSON::PP::false,
                pushed_at => "2026-06-09T00:00:00Z",
                size => 1,
                ssh_url => 'git@github.com:crowdsecurity/.github.git',
                visibility => "public",
            },
        ] if $path =~ /page=1/;
        return [] if $path =~ /page=2/;
        die "unexpected GitHub request: $base_url $path";
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [
                {
                    name => "crowdsecurity",
                    source_group_url => "https://github.com/crowdsecurity",
                    target_namespace_path => "crowdsecurity",
                },
            ],
        }
    );

    is( $inventory->{inventory}->[0]->{projects}->[0]->{path_with_namespace}, "crowdsecurity/.github", "GitHub org discovery accepts public repos like .github that do not fit the stricter GitLab-style path validator" );
}

{
    no warnings 'redefine';

    local *GlabGroups::_get_github_account_installation = sub {
        my ( $base_url, $account, $jwt, $policy ) = @_;
        return { id => 77 };
    };
    local *GlabGroups::_generate_github_app_jwt = sub { return "jwt-token"; };
    local *GlabGroups::_github_request = sub {
        my ( $base_url, $path, $payload, $opt ) = @_;
        is( $opt->{method}, "POST", "GitHub installation token request uses POST" );
        is( $opt->{auth_bearer}, "jwt-token", "GitHub installation token request uses the app JWT" );
        return {
            expires_at => "2030-01-01T00:00:00Z",
            token => "ghs_cached_token",
        };
    };

    my $source_auth = {
        github_app => {
            app_id => "123",
            pem => "unused",
        },
        github_installation_tokens => {},
    };
    my $resolved = GlabGroups::_github_installation_source_auth(
        $source_auth,
        "https://github.com",
        "labwc",
        {},
    );
    is_deeply(
        $resolved,
        {
            token => "ghs_cached_token",
            username => "x-access-token",
        },
        "GitHub installation auth resolves an x-access-token source credential",
    );
}

{
    no warnings 'redefine';

    local *GlabGroups::_get_github_account_installation = sub {
        die "_get_github_account_installation should not be called when GH_ORG_READ_APP_INSTALL_ID is configured";
    };
    local *GlabGroups::_generate_github_app_jwt = sub { return "jwt-token"; };
    local *GlabGroups::_github_request = sub {
        my ( $base_url, $path, $payload, $opt ) = @_;
        is( $path, "/app/installations/88/access_tokens", "GitHub installation token request uses the configured shared installation id" );
        is( $opt->{method}, "POST", "fixed-install GitHub token request uses POST" );
        is( $opt->{auth_bearer}, "jwt-token", "fixed-install GitHub token request uses the app JWT" );
        return {
            expires_at => "2030-01-01T00:00:00Z",
            token => "ghs_shared_install_token",
        };
    };

    my $source_auth = {
        github_app => {
            app_id => "123",
            install_id => "88",
            pem => "unused",
        },
        github_installation_tokens => {},
    };
    my $resolved = GlabGroups::_github_installation_source_auth(
        $source_auth,
        "https://github.com",
        "ignored-source-account",
        {},
    );
    is_deeply(
        $resolved,
        {
            token => "ghs_shared_install_token",
            username => "x-access-token",
        },
        "GitHub installation auth can use the configured shared installation id directly",
    );
}

{
    no warnings 'redefine';

    local *GlabGroups::_github_installation_source_auth = sub {
        die "_github_installation_source_auth should not be called for explicit project sources";
    };

    my $resolved = GlabGroups::_resolve_source_auth_for_entry(
        {
            github_app => {
                app_id => "123",
                install_id => "88",
                pem => "unused",
            },
        },
        {
            source_auth_mode => "none",
            source_http_url => "https://github.com/labwc/labwc.git",
        },
    );
    is_deeply(
        $resolved,
        {
            token => undef,
            username => undef,
        },
        "explicit project mirror entries skip source auth injection entirely",
    );
}

{
    no warnings 'redefine';

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path ) = @_;
        return [ { id => 1, full_path => "plasma", path => "plasma" } ]
          if $method eq "GET" && $path =~ m{\A/groups\?top_level_only=true.*page=1};
        return []
          if $method eq "GET" && $path =~ m{\A/groups\?top_level_only=true.*page=2};
        return { id => 1, full_path => "plasma", path => "plasma" }
          if $method eq "GET" && $path eq "/groups/plasma";
        return [
            {
                archived => JSON::PP::false,
                default_branch => "master",
                description => "KWin",
                empty_repo => JSON::PP::false,
                http_url_to_repo => "https://invent.kde.org/plasma/kwin.git",
                id => 202,
                lfs_enabled => JSON::PP::false,
                path_with_namespace => "plasma/kwin",
                ssh_url_to_repo => 'git@invent.kde.org:plasma/kwin.git',
                visibility => "public",
            },
        ] if $method eq "GET" && $path =~ m{\A/groups/1/projects\?};
        return []
          if $method eq "GET" && $path =~ m{\A/groups/1/subgroups\?};
        die "unexpected gitlab request: $method $path";
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [
                {
                    name => "kde-root",
                    source_group_url => "https://invent.kde.org",
                    target_namespace_path => "kde",
                },
            ],
        }
    );

    is( $inventory->{inventory}->[0]->{group_path}, "plasma", "GitLab instance-root discovery expands the top-level group path" );
    is( $inventory->{inventory}->[0]->{namespace}->{target_namespace_path}, "kde/plasma", "GitLab instance-root discovery prefixes the target namespace with the top-level group path" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{path_with_namespace}, "plasma/kwin", "GitLab instance-root discovery keeps the source project namespace" );
}

{
    no warnings 'redefine';

    local *GlabGroups::_is_gitlab_instance_root = sub { return 0; };
    local *GlabGroups::_http_text_request = sub {
        return <<'HTML';
<html>
  <body>
    <a href="/iptables/">iptables</a>
    <a href="/nftables/">nftables</a>
    <a href="/cgit.css">stylesheet</a>
  </body>
</html>
HTML
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [
                {
                    name => "netfilter-root",
                    source_group_url => "https://git.netfilter.org",
                    target_namespace_path => "netfilter",
                },
            ],
        }
    );

    is( $inventory->{inventory}->[0]->{group_path}, "git.netfilter.org", "cgit root discovery derives a stable synthetic source root key from the host" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{path_with_namespace}, "git.netfilter.org/iptables", "cgit root discovery builds synthetic source project paths beneath the host key" );
    is( $inventory->{inventory}->[0]->{projects}->[1]->{http_url_to_repo}, "https://git.netfilter.org/nftables", "cgit root discovery derives HTTPS clone URLs from the repository name" );
}

{
    no warnings 'redefine';
    local *GlabGroups::_is_gitlab_instance_root = sub {
        die "_is_gitlab_instance_root should not be probed for googlesource roots";
    };
    local *GlabGroups::_http_text_request = sub {
        return <<'HTML';
<html>
  <body>
    <a href="/device/google/akita/">device/google/akita</a>
    <a href="/platform/frameworks/base/">platform/frameworks/base</a>
    <a href="/cgit.css">stylesheet</a>
  </body>
</html>
HTML
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [
                {
                    name => "android-root",
                    source_group_url => "https://android.googlesource.com",
                    target_namespace_path => "android",
                },
            ],
        }
    );

    is( $inventory->{inventory}->[0]->{group_path}, "android.googlesource.com", "gitiles root discovery derives a stable synthetic source root key from the host" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{path_with_namespace}, "android.googlesource.com/device/google/akita", "gitiles root discovery keeps nested repository paths under the synthetic source root" );
    is( $inventory->{inventory}->[0]->{projects}->[1]->{http_url_to_repo}, "https://android.googlesource.com/platform/frameworks/base", "gitiles root discovery derives HTTPS clone URLs for nested repository paths" );
}

{
    no warnings 'redefine';
    my @seen_source_urls;

    local *GlabGroups::_discover_remote_refs = sub {
        my ( $source_url, $policy ) = @_;
        push @seen_source_urls, $source_url;
        return {
            branches => {},
            default_branch => "",
            tags => {},
        } if $source_url eq "https://gitlab.com/WhyNotHugo/darkman";
        return {
            branches => { main => 1, stable => 1 },
            default_branch => "main",
            tags => { "v1.0.0" => 1 },
        } if $source_url eq "https://gitlab.com/WhyNotHugo/darkman.git";
        die "unexpected source url: $source_url";
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [],
            projects => [
                {
                    name => "darkman",
                    source_project_url => "https://gitlab.com/WhyNotHugo/darkman",
                    target_group_path => "glab-forks/labwc",
                },
            ],
        }
    );

    is( $inventory->{inventory}->[0]->{group_path}, "WhyNotHugo", "explicit GitLab project discovery keeps the source owner path" );
    is( $inventory->{inventory}->[0]->{project_entry}->{target_group_path}, "glab-forks/labwc", "explicit project discovery keeps the configured target group path" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{path_with_namespace}, "WhyNotHugo/darkman", "explicit GitLab project discovery keeps the source project path" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{default_branch}, "main", "explicit project discovery records the discovered default branch" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{http_url_to_repo}, "https://gitlab.com/WhyNotHugo/darkman.git", "explicit GitLab project discovery stores the working clone URL" );
    is_deeply(
        \@seen_source_urls,
        [
            "https://gitlab.com/WhyNotHugo/darkman",
            "https://gitlab.com/WhyNotHugo/darkman.git",
        ],
        "explicit GitLab project discovery retries the .git clone URL when the human-facing URL has no branches",
    );
}

{
    no warnings 'redefine';
    my @seen_source_urls;

    local *GlabGroups::_discover_remote_refs = sub {
        my ( $source_url, $policy ) = @_;
        push @seen_source_urls, $source_url;
        return {
            branches => {},
            default_branch => "",
            tags => {},
        } if $source_url eq "https://android.googlesource.com/platform/frameworks/base";
        return {
            branches => { main => 1 },
            default_branch => "main",
            tags => {},
        } if $source_url eq "https://android.googlesource.com/platform/frameworks/base.git";
        die "unexpected source url: $source_url";
    };

    my $chosen_source_url = "https://android.googlesource.com/platform/frameworks/base";
    my $available = GlabGroups::_discover_remote_refs_from_urls(
        [
            $chosen_source_url,
            GlabGroups::_fallback_clone_url($chosen_source_url),
        ],
        {},
        \$chosen_source_url,
    );

    is( $available->{default_branch}, "main", "generic source ref discovery returns the discovered ref set from the working candidate URL" );
    is( $chosen_source_url, "https://android.googlesource.com/platform/frameworks/base.git", "generic source ref discovery keeps the working .git URL when the human-facing URL has no refs" );
    is_deeply(
        \@seen_source_urls,
        [
            "https://android.googlesource.com/platform/frameworks/base",
            "https://android.googlesource.com/platform/frameworks/base.git",
        ],
        "generic source ref discovery retries a .git suffix before failing",
    );
}

{
    no warnings 'redefine';

    local *GlabGroups::_discover_remote_refs = sub {
        my ( $source_url, $policy ) = @_;
        return {
            branches => { main => 1 },
            default_branch => "main",
            tags => {},
        };
    };

    my $inventory = GlabGroups::_discover_inventory(
        {
            defaults => { additional_branches => [], additional_tags => [] },
            namespaces => [],
            projects => [
                {
                    name => "gptfdisk",
                    source_project_url => "https://git.code.sf.net/p/gptfdisk/code",
                    target_group_path => "glab-forks/firmware",
                },
            ],
        }
    );

    is( $inventory->{inventory}->[0]->{group_path}, "git.code.sf.net", "explicit generic project discovery uses the source host as the synthetic group path when the URL path is not repo-shaped" );
    is( $inventory->{inventory}->[0]->{projects}->[0]->{path_with_namespace}, "git.code.sf.net/gptfdisk", "explicit generic project discovery uses the configured project name for the synthetic source path" );
}

{
    my $parsed = GlabGroups::_parse_source_project_url(
        "https://github.com/labwc/labwc",
        "labwc",
    );
    is( $parsed->{clone_url}, "https://github.com/labwc/labwc.git", "GitHub direct project URLs normalize to the .git clone URL" );
    is( $parsed->{path_with_namespace}, "labwc/labwc", "GitHub direct project URLs keep the owner/repo path without a .git suffix" );

    $parsed = GlabGroups::_parse_source_project_url(
        "https://gitlab.com/WhyNotHugo/darkman.git",
        "darkman",
    );
    is( $parsed->{path_with_namespace}, "WhyNotHugo/darkman", "repo-shaped direct project URLs strip an optional .git suffix from the source path" );

    $parsed = GlabGroups::_parse_source_project_url(
        "https://git.sr.ht/~kennylevinsen/seatd",
        "seatd",
    );
    is( $parsed->{clone_url}, "https://git.sr.ht/~kennylevinsen/seatd", "SourceHut project URLs preserve the Git-over-HTTPS clone URL" );
    is( $parsed->{group_path}, "~kennylevinsen", "SourceHut project URLs preserve the tilde-prefixed owner path" );
    is( $parsed->{path_with_namespace}, "~kennylevinsen/seatd", "SourceHut project URLs preserve the owner and project path" );
}

{
    no warnings 'redefine';
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $discover_path = File::Spec->catfile( $dir, "discover.json" );
    my $summary_path = File::Spec->catfile( $dir, "plan.md" );

    write_json_file(
        File::Spec->catfile( $dir, "defaults.json" ),
        {
            kind => "glab-groups/defaults",
            version => 1,
            defaults => {},
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
                    target_owner_path => "glab-forks",
                    target_namespace_path => "kalilinux",
                },
            ],
        }
    );

    local *GlabGroups::_discover_inventory = sub {
        return {
            discovered_at => GlabGroups::_timestamp(),
            inventory => [],
        };
    };

    my $error = q{};
    eval {
        GlabGroups::_cmd_plan(
            "--config-dir",     $dir,
            "--discover-output", $discover_path,
            "--output",         $plan_path,
            "--summary",        $summary_path,
        );
        1;
    } or $error = $@;

    like( $error, qr/discovery produced zero targets; refusing to continue with a no-op mirror plan/, "plan fails closed when discovery yields zero mirror targets" );
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
    my $inferred = GlabGroups::_infer_default_branch_from_heads(
        {
            main => 1,
            feature => 1,
        }
    );
    is( $inferred, "main", "prefers main when a remote omits the HEAD symref" );

    $inferred = GlabGroups::_infer_default_branch_from_heads(
        {
            master => 1,
            stable => 1,
        }
    );
    is( $inferred, "master", "falls back to master when main is absent and HEAD is omitted" );

    $inferred = GlabGroups::_infer_default_branch_from_heads(
        {
            onlybranch => 1,
        }
    );
    is( $inferred, "onlybranch", "uses the sole branch when HEAD is omitted and only one branch exists" );
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
    my $plan = GlabGroups::_build_plan(
        {
            defaults => { additional_branches => [], additional_tags => [], force_lfs => JSON::PP::false },
            exclusions => {},
        },
        {
            inventory => [
                {
                    group_path => "root",
                    namespace => {
                        target_owner_path => "owner",
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
    my $plan = GlabGroups::_build_plan(
        {
            defaults => { additional_branches => [], additional_tags => [], force_lfs => JSON::PP::false },
            exclusions => {},
        },
        {
            inventory => [
                {
                    group_path => "WhyNotHugo",
                    project_entry => {
                        name => "darkman",
                        target_group_path => "glab-forks/labwc",
                    },
                    projects => [
                        {
                            archived => JSON::PP::false,
                            available_branches => [ "main", "release" ],
                            available_tags => [ "v1.0.0" ],
                            default_branch => "main",
                            description => "",
                            description_known => JSON::PP::false,
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://gitlab.com/WhyNotHugo/darkman",
                            lfs_enabled => JSON::PP::false,
                            lfs_enabled_known => JSON::PP::false,
                            path_with_namespace => "WhyNotHugo/darkman",
                            ssh_url_to_repo => "https://gitlab.com/WhyNotHugo/darkman",
                            visibility => "public",
                        },
                    ],
                },
            ],
        },
        25,
    );
    is( $plan->{plan}->[0]->{target_full_path}, "glab-forks/labwc/darkman", "explicit project planning uses the configured target group path without deriving namespace segments from the source path" );
    is( $plan->{plan}->[0]->{target_namespace_path}, "glab-forks/labwc", "explicit project planning keeps the configured target group path as the target namespace path" );
    is( $plan->{plan}->[0]->{target_relative_project_path}, "glab-forks/labwc/darkman", "explicit project planning keys exclusions by the resolved explicit target project path" );
    is_deeply( $plan->{plan}->[0]->{source_available_branches}, [ "main", "release" ], "explicit project planning carries discovered source branches into the plan" );
    is_deeply( $plan->{plan}->[0]->{source_available_tags}, [ "v1.0.0" ], "explicit project planning carries discovered source tags into the plan" );
}

{
    my $plan = GlabGroups::_build_plan(
        {
            defaults => { additional_branches => [], additional_tags => [], force_lfs => JSON::PP::false },
            exclusions => {},
        },
        {
            inventory => [
                {
                    group_path => "crowdsecurity",
                    namespace => {
                        target_owner_path => "glab-forks",
                        target_namespace_path => "crowdsecurity",
                    },
                    projects => [
                        {
                            archived => JSON::PP::false,
                            default_branch => "main",
                            description => "",
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://github.com/crowdsecurity/.github.git",
                            id => 10,
                            lfs_enabled => JSON::PP::false,
                            path_with_namespace => "crowdsecurity/.github",
                            ssh_url_to_repo => "https://github.com/crowdsecurity/.github.git",
                            visibility => "public",
                        },
                    ],
                },
            ],
        },
        25,
    );
    is( $plan->{plan}->[0]->{target_full_path}, "glab-forks/crowdsecurity/.github", "planning preserves the source-relative target path for GitHub repos like .github" );
    is( $plan->{plan}->[0]->{action}, "skip", "planning skips GitHub repo names that GitLab cannot create unchanged" );
    is(
        $plan->{plan}->[0]->{skip_reason},
        "Target GitLab path segment '.github' is invalid: path segments must not start with '-', '_', or '.'",
        "planning records the GitLab path validation reason for unsyncable targets",
    );
    is( $plan->{counts}->{skip}, 1, "invalid GitLab target paths count as skipped rows in the plan" );
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
            group_runners_enabled => JSON::PP::true,
            shared_runners_enabled => JSON::PP::true,
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
    my $plan = GlabGroups::_build_plan(
        {
            defaults => { additional_branches => [], additional_tags => [], force_lfs => JSON::PP::false },
            exclusions => {},
        },
        {
            inventory => [
                {
                    group_path => "root",
                    namespace => {
                        target_owner_path => "owner",
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
    is( $plan->{plan}->[0]->{action}, "sync", "target project state is resolved lazily during mirror execution" );
    ok( !defined $plan->{plan}->[0]->{skip_reason}, "missing target projects do not get a skip reason" );
    ok( !defined $plan->{plan}->[0]->{target_namespace_id}, "plan resolves target groups by path later instead of emitting namespace ids" );
}

{
    my $plan = GlabGroups::_build_plan(
        {
            defaults => {
                additional_branches => [],
                additional_tags => [],
                force_lfs => JSON::PP::false,
            },
            exclusions => {},
        },
        {
            inventory => [
                {
                    group_path => "root",
                    namespace => {
                        target_owner_path => "glab-forks",
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
    is( $plan->{plan}->[0]->{target_full_path}, "glab-forks/mirror/project", "plan uses namespace target_owner_path as the target root" );
    is( $plan->{plan}->[0]->{target_namespace_path}, "glab-forks/mirror", "target namespace path is rooted under namespace target_owner_path" );
    ok( !defined $plan->{plan}->[0]->{target_namespace_id}, "plan leaves missing target namespace ids unresolved until target preparation" );
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
    my $plan = GlabGroups::_build_plan(
        {
            defaults => {
                additional_branches => [],
                additional_tags => [],
                force_lfs => JSON::PP::false,
            },
            exclusions => {},
        },
        {
            inventory => [
                {
                    group_path => "root",
                    namespace => {
                        target_owner_path => "glab-forks",
                        target_namespace_path => "mirror",
                    },
                    projects => [
                        {
                            archived => JSON::PP::false,
                            default_branch => "main",
                            description => "source",
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://example.invalid/root/sub1/project-a.git",
                            id => 10,
                            lfs_enabled => JSON::PP::false,
                            path_with_namespace => "root/sub1/project-a",
                            ssh_url_to_repo => 'git@example.invalid:root/sub1/project-a.git',
                            visibility => "public",
                        },
                        {
                            archived => JSON::PP::false,
                            default_branch => "main",
                            description => "source",
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://example.invalid/root/sub1/project-b.git",
                            id => 11,
                            lfs_enabled => JSON::PP::false,
                            path_with_namespace => "root/sub1/project-b",
                            ssh_url_to_repo => 'git@example.invalid:root/sub1/project-b.git',
                            visibility => "public",
                        },
                        {
                            archived => JSON::PP::false,
                            default_branch => "main",
                            description => "source",
                            empty_repo => JSON::PP::false,
                            http_url_to_repo => "https://example.invalid/root/sub2/project-c.git",
                            id => 12,
                            lfs_enabled => JSON::PP::false,
                            path_with_namespace => "root/sub2/project-c",
                            ssh_url_to_repo => 'git@example.invalid:root/sub2/project-c.git',
                            visibility => "public",
                        },
                    ],
                },
            ],
        },
        2,
    );
    is( $plan->{total_groups}, 2, "planning counts unique target namespace groups" );
    is( $plan->{total_batches}, 2, "group-aware batching splits only at target group boundaries" );
    is_deeply(
        $plan->{batches}->[0]->{group_paths},
        ["glab-forks/mirror/sub1"],
        "first batch keeps the first target subgroup together",
    );
    is_deeply(
        $plan->{batches}->[1]->{group_paths},
        ["glab-forks/mirror/sub2"],
        "second batch carries the remaining subgroup",
    );
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
                    target_owner_path => "glab-forks",
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
    my $random = qx{LC_ALL=C TZ=UTC head -c 1048589 /dev/urandom};
    print {$blob} $random;
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
    cmp_ok( $analysis->{total_bytes}, ">", 1024 * 1024, "counts packed selected-ref bytes" );
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
            counts => { sync => 2, fail => 0, skip => 0 },
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
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $results_ok = File::Spec->catfile( $dir, "results-0.json" );
    my $results_empty = File::Spec->catfile( $dir, "results-1.json" );
    my $report_path = File::Spec->catfile( $dir, "report.json" );
    my $summary_path = File::Spec->catfile( $dir, "report.md" );
    write_json_file(
        $plan_path,
        {
            counts => { sync => 1, fail => 0, skip => 0 },
        }
    );
    write_json_file(
        $results_ok,
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
    write_text_file( $results_empty, q{} );

    is(
        GlabGroups::run_cli(
            "report",
            "--plan", $plan_path,
            "--results", $results_ok,
            "--results", $results_empty,
            "--output", $report_path,
            "--summary", $summary_path,
        ),
        0,
        "report keeps valid shard results when one shard JSON file is empty",
    );
    my $report = JSON::PP->new->decode( do { open( my $fh, "<:encoding(UTF-8)", $report_path ) or die $!; local $/; <$fh> } );
    is( scalar @{ $report->{results} }, 1, "report keeps valid shard rows" );
    is( scalar @{ $report->{input_failures} }, 1, "report records one unreadable shard file" );
    like( $report->{input_failures}->[0]->{error}, qr/empty JSON file/, "report captures the empty-file parse error" );
}

{
    no warnings 'redefine';
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $prepared_path = File::Spec->catfile( $dir, "prepared.json" );
    my $output_path = File::Spec->catfile( $dir, "results.json" );
    my $jsonl_path = File::Spec->catfile( $dir, "results.jsonl" );

    write_json_file(
        $plan_path,
        {
            batches => [
                {
                    start_index => 0,
                    end_index => 0,
                    group_paths => ["owner/group"],
                    target_count => 1,
                },
            ],
            plan => [
                {
                    action => "sync",
                    policy => {},
                    source_default_branch => "main",
                    source_empty_repo => JSON::PP::true,
                    target_full_path => "owner/group/project-a",
                    target_namespace_path => "owner/group",
                },
            ],
        }
    );
    write_json_file(
        $prepared_path,
        {
            prepared => [
                {
                    created => JSON::PP::false,
                    default_branch => "mcr/main",
                    project_id => 99,
                    target_full_path => "owner/group/project-a",
                    updated => JSON::PP::false,
                },
            ],
        }
    );

    local *GlabGroups::_load_target_client = sub { return {}; };
    local *GlabGroups::_load_source_auth = sub { return {}; };
    local *GlabGroups::_ensure_target_project = sub {
        die "_ensure_target_project should not run when --prepared supplies the target state\n";
    };

    is(
        GlabGroups::run_cli(
            "mirror",
            "--plan", $plan_path,
            "--prepared", $prepared_path,
            "--output", $output_path,
            "--jsonl", $jsonl_path,
        ),
        0,
        "mirror reuses prepared shard state instead of re-preparing the target project",
    );
    my $results = JSON::PP->new->decode(
        do {
            open( my $fh, "<:encoding(UTF-8)", $output_path ) or die $!;
            local $/;
            <$fh>;
        }
    );
    is( $results->{results}->[0]->{prepared}->{project_id}, 99, "mirror carries forward prepared project identifiers" );
    ok( $results->{results}->[0]->{verify}->{skipped}, "mirror skips redundant target verification when prepared state is already aligned" );
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
                    action => "sync",
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
        "prepare-target accepts sync entries",
    );
    is_deeply(
        \@prepared_paths,
        [ "owner/group/project-a" ],
        "prepare-target prepares missing target projects",
    );
}

{
    my @prepared_paths;
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $output_path = File::Spec->catfile( $dir, "prepared.json" );
    write_json_file(
        $plan_path,
        {
            batches => [
                {
                    start_index => 0,
                    end_index => 1,
                    group_paths => ["owner/group-a"],
                    target_count => 2,
                },
                {
                    start_index => 2,
                    end_index => 2,
                    group_paths => ["owner/group-b"],
                    target_count => 1,
                },
            ],
            plan => [
                {
                    action => "sync",
                    target_full_path => "owner/group-a/project-a",
                },
                {
                    action => "skip",
                    target_full_path => "owner/group-a/project-b",
                },
                {
                    action => "sync",
                    target_full_path => "owner/group-b/project-c",
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
            "--batch-start", 1,
            "--batch-stride", 2,
            "--batch-limit", 1,
            "--output", $output_path,
        ),
        0,
        "prepare-target accepts batch slicing arguments",
    );
    is_deeply(
        \@prepared_paths,
        [ "owner/group-b/project-c" ],
        "prepare-target prepares only the selected batch shard entries",
    );
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
                    action => "sync",
                    target_full_path => "owner/group/project-a",
                },
                {
                    action => "sync",
                    target_full_path => "owner/group/project-b",
                },
            ],
        }
    );

    local *GlabGroups::_load_target_client = sub { return {}; };
    local *GlabGroups::_ensure_target_project = sub {
        my ( $client, $entry ) = @_;
        push @prepared_paths, $entry->{target_full_path};
        die "path conflict\n" if $entry->{target_full_path} eq "owner/group/project-a";
        return { project_id => 99 };
    };

    is(
        GlabGroups::run_cli(
            "prepare-target",
            "--plan", $plan_path,
            "--output", $output_path,
        ),
        0,
        "prepare-target keeps going after per-entry target preparation failures",
    );
    is_deeply(
        \@prepared_paths,
        [ "owner/group/project-a", "owner/group/project-b" ],
        "prepare-target attempts later entries after one target preparation failure",
    );

    my $prepared = JSON::PP->new->decode(
        do {
            open( my $fh, "<:encoding(UTF-8)", $output_path ) or die $!;
            local $/;
            <$fh>;
        }
    );
    is( $prepared->{prepared_count}, 1, "prepare-target records successful target preparations" );
    is( $prepared->{failure_count}, 1, "prepare-target records failed target preparations" );
    is( $prepared->{failures}->[0]->{target_full_path}, "owner/group/project-a", "prepare-target captures the failed target path" );
}

{
    no warnings 'redefine';
    my $dir = tempdir( CLEANUP => 1 );
    my $plan_path = File::Spec->catfile( $dir, "plan.json" );
    my $output_path = File::Spec->catfile( $dir, "prepared.json" );
    my $calls = 0;

    write_json_file(
        $plan_path,
        {
            plan => [
                {
                    action => "sync",
                    target_full_path => "owner/group/project-a",
                },
                {
                    action => "sync",
                    target_full_path => "owner/group/project-b",
                },
            ],
        }
    );

    local *GlabGroups::_load_target_client = sub { return {}; };
    local *GlabGroups::_ensure_target_project = sub {
        my ( $client, $entry ) = @_;
        $calls++;
        die "gitlab request failed [403] GET /projects/$entry->{target_full_path}: {\"message\":\"403 Forbidden - Your account has been blocked.\"}\n";
    };

    is(
        GlabGroups::run_cli(
            "prepare-target",
            "--plan", $plan_path,
            "--output", $output_path,
        ),
        0,
        "prepare-target stops issuing further API work after the target account is blocked",
    );
    is( $calls, 1, "prepare-target does not retry later entries after a blocked-account error" );
    my $prepared = JSON::PP->new->decode(
        do {
            open( my $fh, "<:encoding(UTF-8)", $output_path ) or die $!;
            local $/;
            <$fh>;
        }
    );
    is( $prepared->{failure_count}, 2, "prepare-target records later entries as blocked failures without reissuing API calls" );
    is( $prepared->{failures}->[1]->{failure_context}, "prepare-target", "later entries are marked with the blocked-account prepare context" );
}

{
    no warnings 'redefine';
    my %cache = ( owner => 7 );

    local *GlabGroups::_ensure_main_user_group_membership_owner = sub { return 1; };
    local *GlabGroups::_ensure_service_user_group_membership_owner = sub { return 1; };

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
        return {
            id => 42,
            full_path => "owner/MixedCase-team",
            path => "MixedCase-team",
            project_creation_level => $payload->{project_creation_level},
            shared_runners_setting => $payload->{shared_runners_setting},
            subgroup_creation_level => $payload->{subgroup_creation_level},
        } if $method eq "PUT" && $path eq "/groups/42";
        return { id => 55, username => "svc-glab" }
          if $method eq "GET" && $path eq "/user";
        return { access_level => 50, id => 55 }
          if $method eq "GET" && $path eq "/groups/42/members/55";
        return { access_level => 40, id => 55 }
          if $method eq "PUT" && $path eq "/groups/42/members/55";
        die "unexpected gitlab request: $method $path";
    };

    my $group_id = GlabGroups::_ensure_group_path( {}, "owner/MixedCase-team", \%cache );
    is( $group_id, 42, "reuses existing group after path conflict" );
    is( $cache{"owner/MixedCase-team"}, 42, "caches resolved group id after conflict lookup" );
}

{
    no warnings 'redefine';
    my %cache = ( owner => 7 );

    local *GlabGroups::_ensure_main_user_group_membership_owner = sub { return 1; };
    local *GlabGroups::_ensure_service_user_group_membership_owner = sub { return 1; };

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
        return {
            id => 84,
            full_path => "owner/freedesktop",
            path => "freedesktop",
            project_creation_level => $payload->{project_creation_level},
            shared_runners_setting => $payload->{shared_runners_setting},
            subgroup_creation_level => $payload->{subgroup_creation_level},
        } if $method eq "PUT" && $path eq "/groups/84";
        return { id => 55, username => "svc-glab" }
          if $method eq "GET" && $path eq "/user";
        return { access_level => 50, id => 55 }
          if $method eq "GET" && $path eq "/groups/84/members/55";
        return { access_level => 40, id => 55 }
          if $method eq "PUT" && $path eq "/groups/84/members/55";
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

    local *GlabGroups::_ensure_main_user_group_membership_owner = sub { return 1; };
    local *GlabGroups::_ensure_service_user_group_membership_owner = sub { return 1; };

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
        return {
            id => 99,
            full_path => "owner/freedesktop/wlroots",
            path => "wlroots",
            project_creation_level => $payload->{project_creation_level},
            shared_runners_setting => $payload->{shared_runners_setting},
            subgroup_creation_level => $payload->{subgroup_creation_level},
        } if $method eq "PUT" && $path eq "/groups/99";
        return { id => 55, username => "svc-glab" }
          if $method eq "GET" && $path eq "/user";
        return { access_level => 50, id => 55 }
          if $method eq "GET" && $path eq "/groups/99/members/55";
        return { access_level => 40, id => 55 }
          if $method eq "PUT" && $path eq "/groups/99/members/55";
        die "unexpected gitlab request: $method $path";
    };

    my $group_id = GlabGroups::_ensure_group_path( {}, "owner/freedesktop/wlroots", \%cache );
    is( $group_id, 99, "reuses existing nested group after search fallback misses it" );
    is( $cache{"owner/freedesktop/wlroots"}, 99, "caches nested group id after enumerating existing subgroups" );
}

{
    no warnings 'redefine';
    my %cache = ( owner => 7 );

    local *GlabGroups::_ensure_main_user_group_membership_owner = sub { return 1; };
    local *GlabGroups::_ensure_service_user_group_membership_owner = sub { return 1; };

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
    my %cache = ( "glab-forks" => 7 );

    local *GlabGroups::_ensure_main_user_group_membership_owner = sub { return 1; };
    local *GlabGroups::_ensure_service_user_group_membership_owner = sub { return 1; };

    local *GlabGroups::_get_group = sub {
        my ( $client, $group_path ) = @_;
        return undef if $group_path eq "glab-forks/crowdsecurity";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        if ( $method eq "POST" && $path eq "/groups" ) {
            die "gitlab request failed [403] POST /groups: {\"message\":\"403 Forbidden\"}\n";
        }
        die "unexpected gitlab request: $method $path";
    };

    my $ok = eval {
        GlabGroups::_ensure_group_path( {}, "glab-forks/crowdsecurity", \%cache );
        1;
    };
    ok( !$ok, "forbidden group creation still fails closed" );
    like( $@, qr/unable to create required target group glab-forks\/crowdsecurity:/, "forbidden group creation reports the exact target namespace path" );
    like( $@, qr/pre-create it or grant group creation rights/i, "forbidden group creation explains how to fix the permission boundary" );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;

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
        ] if $method eq "GET" && $path eq "/groups/1/projects?include_subgroups=false&with_shared=false&per_page=100&page=1";
        return [
            { id => 2, full_path => "root/sub", path => "sub" },
        ] if $method eq "GET" && $path eq "/groups/1/subgroups?per_page=100&page=1";
        return [
            { id => 102, path_with_namespace => "root/sub/project-b" },
        ] if $method eq "GET" && $path eq "/groups/2/projects?include_subgroups=false&with_shared=false&per_page=100&page=1";
        return [] if $method eq "GET" && $path eq "/groups/2/subgroups?per_page=100&page=1";
        die "unexpected gitlab request: $method $path";
    };

    my $projects = GlabGroups::_list_group_projects(
        {},
        "root",
        {
            read_retry_attempts => 2,
            read_retry_backoff_seconds => 5,
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
    is( $requests[0]->{opt}->{retry_attempts}, 2, "group inventory uses the read-specific retry attempts" );
    is( $requests[0]->{opt}->{retry_backoff_seconds}, 5, "group inventory uses the read-specific retry backoff" );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, opt => $opt };
        return { id => 1, full_path => "root", path => "root" }
          if $method eq "GET" && $path eq "/groups/root";
        return [
            { id => 101, path_with_namespace => "root/project-a" },
            { id => 102, path_with_namespace => "root/sub/project-b" },
        ] if $method eq "GET" && $path eq "/groups/1/projects?include_subgroups=true&with_shared=false&per_page=100&page=1";
        return [] if $method eq "GET" && $path eq "/groups/1/projects?include_subgroups=true&with_shared=false&per_page=100&page=2";
        die "unexpected gitlab request: $method $path";
    };

    my $projects = GlabGroups::_list_group_projects(
        {},
        "root",
        {
            gitlab_source_include_subgroups => JSON::PP::true,
            read_retry_attempts => 2,
            read_retry_backoff_seconds => 5,
        }
    );
    is_deeply(
        [ map { $_->{path_with_namespace} } @{$projects} ],
        [ "root/project-a", "root/sub/project-b" ],
        "include_subgroups discovery can enumerate subgroup projects without subgroup traversal",
    );
    ok(
        !( scalar grep { $_->{path} =~ /\/subgroups\?/ } @requests ),
        "include_subgroups discovery avoids subgroup listing API calls",
    );
    ok(
        scalar( grep { $_->{path} =~ /include_subgroups=true/ } @requests ),
        "include_subgroups discovery uses the GitLab include_subgroups project listing mode",
    );
}

{
    my $opt = GlabGroups::_git_command_options(
        {
            read_retry_attempts => 2,
            read_retry_backoff_seconds => 5,
            retry_attempts => 7,
            retry_backoff_seconds => 9,
        },
        JSON::PP::true,
    );
    is( $opt->{retry_attempts}, 7, "git command retries continue to use retry_attempts" );
    is( $opt->{retry_backoff_seconds}, 9, "git command retries continue to use retry_backoff_seconds" );
}

{
    no warnings 'redefine';
    my %cache;
    my @payloads;

    local *GlabGroups::_ensure_main_user_group_membership_owner = sub { return 1; };
    local *GlabGroups::_ensure_service_user_group_membership_owner = sub { return 1; };

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
    is( $payloads[0]->{project_creation_level}, "maintainer", "group creation sets maintainer project creation level" );
    is( $payloads[0]->{shared_runners_setting}, "disabled_and_unoverridable", "group creation disables instance runners for descendants" );
    is( $payloads[0]->{subgroup_creation_level}, "maintainer", "group creation allows maintainers to create subgroups" );
    ok( !exists $payloads[0]->{visibility}, "group creation payload does not set visibility" );
}

{
    no warnings 'redefine';
    my %cache = ( owner => 7 );

    local *GlabGroups::_get_group = sub {
        my ( $client, $group_path ) = @_;
        return {
            id => 11,
            full_path => "owner/team",
            path => "team",
            project_creation_level => "developer",
            shared_runners_setting => "enabled",
            subgroup_creation_level => "owner",
        } if $group_path eq "owner/team";
        die "unexpected group lookup: $group_path";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        die "unexpected gitlab request: $method $path";
    };

    my $group_id = GlabGroups::_ensure_group_path( {}, "owner/team", \%cache );
    is( $group_id, 11, "reuses existing target group without mutating ancestor groups" );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;

    local *GlabGroups::_get_project = sub {
        my ( $client, $project_path ) = @_;
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @resolved_namespaces, $group_path;
        return 42;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return []
          if $method eq "GET"
          && (
            $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=project&simple=true"
            || $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
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
            target_namespace_path => "owner/group",
        }
    );
    ok( $result->{created}, "creates missing target project" );
    is_deeply( \@resolved_namespaces, [ "owner/group" ], "project creation resolves the target namespace path on demand" );
    my ($create_request) = grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests;
    ok( $create_request, "issues project creation API calls when target is missing" );
    is( $create_request->{path}, "/projects", "creates project through the GitLab projects API" );
    ok( !$create_request->{payload}->{group_runners_enabled}, "project creation disables group runners" );
    ok( !$create_request->{payload}->{shared_runners_enabled}, "project creation disables instance runners" );
    ok( !exists $create_request->{payload}->{visibility}, "project creation payload does not set visibility" );
}

{
    no warnings 'redefine';
    my @requests;

    local *GlabGroups::_get_project = sub {
        my ( $client, $project_path ) = @_;
        return {
            id => 321,
            archived => JSON::PP::false,
            description => "existing",
            group_runners_enabled => JSON::PP::false,
            lfs_enabled => JSON::PP::false,
            shared_runners_enabled => JSON::PP::false,
        } if $project_path eq "owner/group/project";
        return undef;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return { id => 321, archived => JSON::PP::false };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "existing",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "owner/group/project",
            target_namespace_path => "owner/group",
        }
    );
    ok( !$result->{created}, "reuses an existing target project found by exact full path lookup" );
    is( scalar @requests, 0, "does not issue create or update requests when the exact target project path already exists" );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;
    my $project_search_calls = 0;

    local *GlabGroups::_get_project = sub {
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @resolved_namespaces, $group_path;
        return 77;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return [
            {
                id => 654,
                archived => JSON::PP::false,
                description => "existing",
                group_runners_enabled => JSON::PP::false,
                lfs_enabled => JSON::PP::false,
                path => "project",
                path_with_namespace => "owner/group/project",
                shared_runners_enabled => JSON::PP::false,
            },
        ] if $method eq "GET"
          && (
            $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=project&simple=true"
            || $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
        die "unexpected gitlab request: $method $path";
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "existing",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "owner/group/project",
            target_namespace_path => "owner/group",
        }
    );
    ok( !$result->{created}, "reuses an existing target project found by namespace-scoped project search" );
    is_deeply( \@resolved_namespaces, [ "owner/group" ], "existing project fallback still resolves the exact target namespace path once" );
    is(
        scalar( grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests ),
        0,
        "namespace-scoped existing project fallback avoids unnecessary project creation attempts",
    );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;
    my $project_search_calls = 0;

    local *GlabGroups::_get_project = sub {
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @resolved_namespaces, $group_path;
        return 77;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        die "gitlab request failed [400] POST /projects: {\"message\":{\"base\":[\"path has already been taken\"]}}\n"
          if $method eq "POST" && $path eq "/projects";
        if ( $method eq "GET"
            && (
                $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=project&simple=true"
                || $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
            ) )
        {
            $project_search_calls++;
            return [] if $project_search_calls <= 2;
            return [
                {
                    id => 655,
                    archived => JSON::PP::false,
                    description => "existing",
                    group_runners_enabled => JSON::PP::false,
                    lfs_enabled => JSON::PP::false,
                    path => "project",
                    path_with_namespace => "owner/group/project",
                    shared_runners_enabled => JSON::PP::false,
                },
            ];
        }
        die "unexpected gitlab request: $method $path";
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "existing",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "owner/group/project",
            target_namespace_path => "owner/group",
        }
    );
    ok( !$result->{created}, "reuses an existing target project after a create path conflict" );
    is_deeply( \@resolved_namespaces, [ "owner/group" ], "path conflict recovery keeps the target namespace resolution stable" );
    is(
        scalar( grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests ),
        1,
        "path conflict recovery attempts project creation only once before reusing the existing target",
    );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;
    my @resolved_ids = ( 42, 77 );

    local *GlabGroups::_get_project = sub {
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @resolved_namespaces, $group_path;
        return shift @resolved_ids;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        die "gitlab request failed [400] POST /projects: {\"message\":{\"base\":[\"path has already been taken\"]}}\n"
          if $method eq "POST"
          && $path eq "/projects"
          && $payload->{namespace_id} == 42;
        return []
          if $method eq "GET"
          && (
            $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=yubikey-piv-manager&simple=true"
            || $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
        return [
            {
                id => 901,
                archived => JSON::PP::false,
                description => "existing",
                group_runners_enabled => JSON::PP::false,
                lfs_enabled => JSON::PP::false,
                path => "yubikey-piv-manager",
                path_with_namespace => "glab-forks/debian/auth-team/yubikey-piv-manager",
                shared_runners_enabled => JSON::PP::false,
            },
        ] if $method eq "GET"
          && (
            $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=yubikey-piv-manager&simple=true"
            || $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
        die "unexpected gitlab request: $method $path";
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "existing",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "glab-forks/debian/auth-team/yubikey-piv-manager",
            target_namespace_path => "glab-forks/debian/auth-team",
        }
    );
    ok( !$result->{created}, "reuses an existing target project after re-resolving a stale nested namespace on project path conflict" );
    is_deeply(
        \@resolved_namespaces,
        [ "glab-forks/debian/auth-team", "glab-forks/debian/auth-team" ],
        "project path conflict recovery re-resolves the exact nested target namespace path before reusing the existing project",
    );
    is_deeply(
        [ map { $_->{payload}->{namespace_id} } grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests ],
        [42],
        "project path conflict recovery does not create a duplicate project once the refreshed nested namespace lookup finds the existing target",
    );
}

{
    no warnings 'redefine';
    my @requests;
    my @ensured_groups;

    local *GlabGroups::_get_project = sub {
        return undef;
    };

    local *GlabGroups::_get_group = sub {
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @ensured_groups, $group_path;
        return 77;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return []
          if $method eq "GET"
          && (
            $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=project&simple=true"
            || $path eq "/groups/77/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
        return { id => 123, archived => JSON::PP::false };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "source",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "owner/group/project",
            target_namespace_path => "owner/group",
        }
    );
    ok( $result->{created}, "creates missing target project after resolving the target namespace on demand" );
    is_deeply( \@ensured_groups, [ "owner/group" ], "resolves the target namespace only when project preparation needs it" );
    my ($create_request) = grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests;
    is( $create_request->{payload}->{namespace_id}, 77, "project creation uses the resolved namespace id" );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;

    local *GlabGroups::_get_project = sub {
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @resolved_namespaces, $group_path;
        return 88;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return []
          if $method eq "GET"
          && (
            $path eq "/groups/88/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=crowdsec&simple=true"
            || $path eq "/groups/88/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
        return { id => 123, archived => JSON::PP::false };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "source",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "glab-forks/crowdsecurity/crowdsec",
            target_namespace_path => "glab-forks/crowdsecurity",
        }
    );
    ok( $result->{created}, "creates missing target project after resolving the live target group id" );
    is_deeply( \@resolved_namespaces, [ "glab-forks/crowdsecurity" ], "checks the exact target namespace path before creating the target project" );
    is_deeply(
        [ map { $_->{payload}->{namespace_id} } grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests ],
        [88],
        "uses the live namespace id when the configured target namespace path already exists",
    );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;
    my @resolved_ids = ( 42, 77 );

    local *GlabGroups::_get_project = sub {
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @resolved_namespaces, $group_path;
        return shift @resolved_ids;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return []
          if $method eq "GET"
          && (
            $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=user-recovery-tools&simple=true"
            || $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
        die "gitlab request failed [400] POST /projects: {\"message\":{\"namespace\":[\"is not valid\"]}}\n"
          if $method eq "POST"
          && $path eq "/projects"
          && $payload->{namespace_id} == 42;
        return [
            {
                id => 66,
                full_path => "glab-forks",
                path => "glab-forks",
            },
        ] if $method eq "GET"
          && $path eq "/groups?top_level_only=true&per_page=100&page=1&search=glab-forks";
        return [
            {
                id => 77,
                full_path => "glab-forks/google",
                path => "google",
            },
        ] if $method eq "GET"
          && $path eq "/groups/66/subgroups?per_page=100&page=1&search=google";
        return { id => 124, archived => JSON::PP::false };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "source",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "glab-forks/google/user-recovery-tools",
            target_namespace_path => "glab-forks/google",
        }
    );
    ok( $result->{created}, "retries project creation after refreshing an invalid target namespace id" );
    is_deeply(
        [ map { $_->{payload}->{namespace_id} } grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests ],
        [ 42, 77 ],
        "invalid namespace retries use the refreshed target group id",
    );
    is_deeply(
        \@resolved_namespaces,
        [ "glab-forks/google", "glab-forks/google" ],
        "invalid namespace refresh re-resolves the exact target namespace path before retrying",
    );
}

{
    no warnings 'redefine';
    my @requests;
    my @resolved_namespaces;
    my @resolved_ids = ( 42, 77 );

    local *GlabGroups::_get_project = sub {
        return undef;
    };

    local *GlabGroups::_ensure_group_path = sub {
        my ( $client, $group_path, $cache ) = @_;
        push @resolved_namespaces, $group_path;
        return shift @resolved_ids;
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return []
          if $method eq "GET"
          && (
            $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&search=user-recovery-tools&simple=true"
            || $path eq "/groups/42/projects?include_subgroups=false&with_shared=false&per_page=100&page=1&simple=true"
          );
        die "gitlab request failed [400] POST /projects: {\"message\":{\"namespace_id\":[\"does not exist\"]}}\n"
          if $method eq "POST"
          && $path eq "/projects"
          && $payload->{namespace_id} == 42;
        return [
            {
                id => 66,
                full_path => "glab-forks",
                path => "glab-forks",
            },
        ] if $method eq "GET"
          && $path eq "/groups?top_level_only=true&per_page=100&page=1&search=glab-forks";
        return [
            {
                id => 77,
                full_path => "glab-forks/google",
                path => "google",
            },
        ] if $method eq "GET"
          && $path eq "/groups/66/subgroups?per_page=100&page=1&search=google";
        return { id => 124, archived => JSON::PP::false };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_archived => JSON::PP::false,
            source_description => "source",
            source_lfs_enabled => JSON::PP::false,
            target_full_path => "glab-forks/google/user-recovery-tools",
            target_namespace_path => "glab-forks/google",
        }
    );
    ok( $result->{created}, "retries project creation after refreshing a namespace_id does not exist error" );
    is_deeply(
        [ map { $_->{payload}->{namespace_id} } grep { $_->{method} eq "POST" && $_->{path} eq "/projects" } @requests ],
        [ 42, 77 ],
        "stale configured namespace ids are refreshed even when GitLab reports namespace_id does not exist",
    );
    is_deeply(
        \@resolved_namespaces,
        [ "glab-forks/google", "glab-forks/google" ],
        "namespace_id does not exist retries re-resolve the same target path before retrying",
    );
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
            batches => [
                {
                    end_index => 0,
                    group_paths => ["owner/group"],
                    start_index => 0,
                    target_count => 1,
                },
            ],
            plan => [
                {
                    action => "sync",
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
    my %branches = (
        main => { name => "main", protected => JSON::PP::false },
        "mcr/release" => { name => "mcr/release", protected => JSON::PP::true },
        "mcr/staging" => { name => "mcr/staging", protected => JSON::PP::true },
    );

    local *GlabGroups::_get_branch = sub {
        my ( $client, $project_id, $branch_name ) = @_;
        my $branch = $branches{$branch_name};
        return undef unless $branch;
        return { %{$branch} };
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        if ( $method eq "POST" && $path eq "/projects/99/repository/branches" ) {
            die "Branch already exists\n" if exists $branches{ $payload->{branch} };
            $branches{ $payload->{branch} } = {
                name => $payload->{branch},
                protected => JSON::PP::false,
            };
            return { %{ $branches{ $payload->{branch} } } };
        }
        if ( $method eq "GET" && $path eq "/projects/99/protected_branches" ) {
            return [
                map { { %{$_} } }
                  sort { $a->{name} cmp $b->{name} }
                  grep { $_->{protected} } values %branches
            ];
        }
        if ( $method eq "GET" && $path =~ m{\A/projects/99/protected_branches/} ) {
            my ($branch_name) = $path =~ m{\A/projects/99/protected_branches/(.+)\z};
            $branch_name =~ s/%2F/\//g;
            return undef if !exists $branches{$branch_name} || !$branches{$branch_name}->{protected};
            return { %{ $branches{$branch_name} } };
        }
        if ( $method eq "POST" && $path eq "/projects/99/protected_branches" ) {
            $branches{ $payload->{name} } ||= { name => $payload->{name} };
            $branches{ $payload->{name} }->{protected} = JSON::PP::true;
            return { %{ $branches{ $payload->{name} } } };
        }
        if ( $method eq "DELETE" && $path =~ m{\A/projects/99/protected_branches/} ) {
            my ($branch_name) = $path =~ m{\A/projects/99/protected_branches/(.+)\z};
            $branch_name =~ s/%2F/\//g;
            if ( exists $branches{$branch_name} ) {
                $branches{$branch_name}->{protected} = JSON::PP::false;
            }
            return undef;
        }
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
            target_description => "old",
            target_group_runners_enabled => JSON::PP::true,
            target_shared_runners_enabled => JSON::PP::true,
            target_lfs_enabled => JSON::PP::false,
            target_namespace_path => "owner/group",
            target_project_id => 99,
        }
    );
    ok( !$result->{created}, "does not create when project already exists" );
    ok( $result->{updated}, "updates existing target project metadata when needed" );
    ok( !$requests[0]->{payload}->{group_runners_enabled}, "project update disables group runners" );
    ok( !$requests[0]->{payload}->{shared_runners_enabled}, "project update disables instance runners" );
    ok( !exists $requests[0]->{payload}->{visibility}, "project update payload does not set visibility" );

    GlabGroups::_finalize_target_project(
        {},
        99,
        "main",
        {
            policy => {
                target_branches_protect => [
                    { name => "gitlab/mcr/main" },
                ],
            },
            source_description => "source",
        }
    );
    my @branch_create_requests =
      grep { $_->{method} eq "POST" && $_->{path} eq "/projects/99/repository/branches" } @requests;
    is_deeply(
        [ map { $_->{payload}->{branch} } @branch_create_requests ],
        [ "gitlab/mcr/main", "mcr/main", "mcr/feature/init", "mcr/staging", "mcr/release" ],
        "finalize bootstraps the managed target branches in order",
    );
    is_deeply(
        [ map { $_->{payload}->{ref} } @branch_create_requests ],
        [ "main", "gitlab/mcr/main", "mcr/main", "mcr/main", "mcr/main" ],
        "managed target branches are created from the expected refs",
    );
    my @protect_requests =
      grep { $_->{method} eq "POST" && $_->{path} eq "/projects/99/protected_branches" } @requests;
    is_deeply(
        [ map { $_->{payload}->{name} } @protect_requests ],
        [ "gitlab/mcr/main" ],
        "finalize protects only the configured target branches",
    );
    my @unprotect_requests =
      grep { $_->{method} eq "DELETE" && $_->{path} =~ m{\A/projects/99/protected_branches/} } @requests;
    is_deeply(
        [ map { my ($name) = $_->{path} =~ m{\A/projects/99/protected_branches/(.+)\z}; $name =~ s/%2F/\//gr } @unprotect_requests ],
        [ "mcr/release", "mcr/staging" ],
        "finalize removes legacy protection from managed branches not present in config",
    );
    my @project_put_requests = grep { $_->{method} eq "PUT" && $_->{path} eq "/projects/99" } @requests;
    ok( !exists $project_put_requests[-1]->{payload}->{visibility}, "project finalize payload does not set visibility" );
    is( $project_put_requests[-1]->{payload}->{default_branch}, "mcr/main", "project finalize makes mcr/main the default branch" );
}

{
    no warnings 'redefine';
    my @requests;

    local *GlabGroups::_get_project = sub {
        die "_get_project should not be called when plan already supplied the target project metadata";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return { id => 77, archived => JSON::PP::false, description => "keep me", lfs_enabled => JSON::PP::true };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_description => "",
            source_description_known => JSON::PP::false,
            source_lfs_enabled => JSON::PP::false,
            source_lfs_enabled_known => JSON::PP::false,
            target_description => "keep me",
            target_full_path => "glab-forks/labwc/darkman",
            target_group_runners_enabled => JSON::PP::false,
            target_shared_runners_enabled => JSON::PP::false,
            target_lfs_enabled => JSON::PP::true,
            target_namespace_path => "glab-forks/labwc",
            target_project_id => 77,
        }
    );
    ok( !$result->{updated}, "explicit project updates skip description and LFS metadata drift when the source does not provide authoritative values" );
    is( scalar @requests, 0, "explicit project metadata gaps do not trigger project update API calls" );
}

{
    no warnings 'redefine';
    my @requests;

    local *GlabGroups::_get_project = sub {
        die "_get_project should not be called when plan already supplied the target project metadata";
    };

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        push @requests, { method => $method, path => $path, payload => $payload };
        return {
            id => 88,
            archived => JSON::PP::false,
            description => "source",
            group_runners_enabled => JSON::PP::false,
            lfs_enabled => JSON::PP::false,
            shared_runners_enabled => JSON::PP::false,
        };
    };

    my $result = GlabGroups::_ensure_target_project(
        {},
        {
            policy => { force_lfs => JSON::PP::false },
            source_description => "source",
            source_lfs_enabled => JSON::PP::false,
            source_lfs_enabled_known => JSON::PP::true,
            target_description => "source",
            target_full_path => "glab-forks/labwc/group-runners-drift",
            target_group_runners_enabled => JSON::PP::true,
            target_shared_runners_enabled => JSON::PP::true,
            target_lfs_enabled => JSON::PP::false,
            target_namespace_path => "glab-forks/labwc",
            target_project_id => 88,
        }
    );

    ok( $result->{updated}, "existing projects update when group runners remain enabled" );
    is( scalar @requests, 1, "group runners drift triggers exactly one project update call" );
    ok( !$requests[0]->{payload}->{group_runners_enabled}, "group runners drift is corrected by disabling group runners" );
    ok( !$requests[0]->{payload}->{shared_runners_enabled}, "instance runners drift is corrected by disabling instance runners" );
}

{
    no warnings 'redefine';
    my @calls;
    local *GlabGroups::_run_command = sub {
        my ( $args, $opt ) = @_;
        push @calls, [ @{$args} ];
        return {
            status => 0,
            output => scalar(@calls) == 1
                ? "{\"message\":{\"base\":[\"Request timed out. Please try again.\"]}}\n400"
                : "{\"id\":99}\n201",
        };
    };

    my $result = GlabGroups::_gitlab_request(
        { base_url => "https://gitlab.example.invalid", token => "secret" },
        "POST",
        "/projects",
        { name => "demo" },
        { retry_attempts => 2, retry_backoff_seconds => 1 },
    );
    is( scalar @calls, 2, "gitlab request retries a transient Request timed out 400 response" );
    is( $result->{id}, 99, "gitlab request returns the successful retry payload" );
}

{
    no warnings 'redefine';

    local *GlabGroups::_gitlab_request = sub {
        my ( $client, $method, $path, $payload, $opt ) = @_;
        return undef
          if $method eq "GET"
          && $path eq "/projects/99/protected_branches/gitlab%2Fmcr%2Fmain";
        die "already exists\n"
          if $method eq "POST"
          && $path eq "/projects/99/protected_branches";
        die "unexpected request: $method $path";
    };

    my $ok = eval {
        GlabGroups::_ensure_target_branch_protected( {}, 99, "gitlab/mcr/main" );
        1;
    };

    ok( !$ok, "protect branch fails when GitLab reports already exists but the exact protected branch is still missing" );
    like( $@, qr/protected branch missing after already-exists response: gitlab\/mcr\/main/, "protect branch reports the missing exact protected branch" );
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
    no warnings 'redefine';
    my @refspecs;

    local *GlabGroups::_run_command = sub {
        my ( $cmd, $opt ) = @_;
        push @refspecs, $cmd->[-1] if $cmd->[3] eq "push";
        return { output => q{}, status => 0 };
    };

    GlabGroups::_push_selected_refs(
        "/tmp/repo",
        {
            branches => [ "main", "release" ],
            tags => ["v1.0.0"],
        },
        {
            git_timeout_seconds => 60,
            retry_attempts => 1,
            retry_backoff_seconds => 1,
        },
        "main",
    );

    is_deeply(
        \@refspecs,
        [
            "refs/heads/release:refs/heads/release",
            "refs/heads/main:refs/heads/gitlab/mcr/main",
            "refs/tags/v1.0.0:refs/tags/v1.0.0",
        ],
        "push_selected_refs mirrors the source default branch only to gitlab/mcr/main",
    );
}

{
    no warnings 'redefine';
    my @refspecs;

    local *GlabGroups::_run_command = sub {
        my ( $cmd, $opt ) = @_;
        push @refspecs, $cmd->[-1] if $cmd->[3] eq "push";
        return { output => q{}, status => 0 };
    };

    GlabGroups::_push_selected_refs(
        "/tmp/repo",
        {
            branches => [ "main", "release" ],
            tags => ["v1.0.0"],
        },
        {
            additional_branches => [ { name => "main" }, { name => "release" } ],
            git_timeout_seconds => 60,
            retry_attempts => 1,
            retry_backoff_seconds => 1,
        },
        "main",
    );

    is_deeply(
        \@refspecs,
        [
            "refs/heads/main:refs/heads/main",
            "refs/heads/release:refs/heads/release",
            "refs/heads/main:refs/heads/gitlab/mcr/main",
            "refs/tags/v1.0.0:refs/tags/v1.0.0",
        ],
        "push_selected_refs also mirrors the source default branch by name when it is explicitly listed in additional_branches",
    );
}

{
    no warnings 'redefine';

    local *GlabGroups::_get_project = sub {
        my ( $client, $project_path ) = @_;
        return { default_branch => "mcr/main", id => 99 };
    };

    local *GlabGroups::_get_branch = sub {
        my ( $client, $project_id, $branch_name ) = @_;
        return { name => $branch_name } if $branch_name eq "gitlab/mcr/main" || $branch_name eq "release";
        return undef;
    };

    local *GlabGroups::_get_tag = sub {
        my ( $client, $project_id, $tag_name ) = @_;
        return undef;
    };

    my $verify = GlabGroups::_verify_entry(
        {},
        {
            target_full_path => "owner/group/project",
        },
        {
            branches => [ "main", "release" ],
            tags => [],
        },
        "main",
    );

    is_deeply(
        $verify->{branches},
        {
            "gitlab/mcr/main" => JSON::PP::true,
            "release" => JSON::PP::true,
        },
        "verify_entry checks the managed sync branch instead of target main",
    );
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
