package GlabGroups;

use strict;
use warnings;

use Exporter qw(import);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;
use POSIX qw(strftime);
use Time::HiRes qw(sleep);
use URI::Escape qw(uri_escape_utf8);

our @EXPORT_OK = qw(
  analyze_selected_refs
  classify_plan_action
  load_config_dir
  resolve_selected_refs
  run_cli
);

my $JSON = JSON::PP->new->canonical(1)->utf8(1);

my %DEFAULTS = (
    allow_blob_rewrite => JSON::PP::true,
    batch_size => 25,
    force_lfs => JSON::PP::false,
    git_timeout_seconds => 1800,
    max_blob_bytes => 100 * 1024 * 1024,
    mirror_pristine_tar => JSON::PP::true,
    retry_attempts => 3,
    retry_backoff_seconds => 2,
    size_limit_bytes => 10 * 1024 * 1024 * 1024,
    visibility => "public",
);

sub run_cli {
    my (@argv) = @_;
    my $command = shift @argv or die _usage();

    if ( $command eq "discover" ) {
        return _cmd_discover(@argv);
    }
    if ( $command eq "normalize" ) {
        return _cmd_normalize(@argv);
    }
    if ( $command eq "plan" ) {
        return _cmd_plan(@argv);
    }
    if ( $command eq "prepare-target" ) {
        return _cmd_prepare_target(@argv);
    }
    if ( $command eq "mirror" ) {
        return _cmd_mirror(@argv);
    }
    if ( $command eq "verify" ) {
        return _cmd_verify(@argv);
    }
    if ( $command eq "report" ) {
        return _cmd_report(@argv);
    }
    if ( $command eq "resume" ) {
        return _cmd_resume(@argv);
    }
    die _usage();
}

sub _usage {
    return <<"USAGE";
usage: perl glab_groups.pl <command> [options]

commands:
  discover
  normalize
  plan
  prepare-target
  mirror
  verify
  report
  resume
USAGE
}

sub load_config_dir {
    my ($config_dir) = @_;
    defined $config_dir && -d $config_dir or die "config dir not found: $config_dir\n";

    opendir( my $dh, $config_dir ) or die "unable to read config dir: $config_dir\n";
    my @files = sort grep { /\.json\z/ && -f File::Spec->catfile( $config_dir, $_ ) } readdir($dh);
    closedir($dh);

    my %config = (
        defaults => { %DEFAULTS, additional_branches => [], additional_tags => [] },
        namespaces => [],
        overrides => {},
        exclusions => {},
    );

    for my $file (@files) {
        my $payload = _read_json( File::Spec->catfile( $config_dir, $file ) );
        ref($payload) eq "HASH" or die "config payload must be an object: $file\n";
        my $kind = _required_string( $payload->{kind}, "$file.kind" );

        if ( $kind eq "glab-groups/defaults" ) {
            my $defaults = _normalize_defaults_payload( $payload->{defaults}, $file );
            %config = (
                %config,
                defaults => { %{ $config{defaults} }, %{$defaults} },
            );
            next;
        }

        if ( $kind eq "glab-groups/namespaces" ) {
            my $roots = $payload->{namespaces};
            ref($roots) eq "ARRAY" or die "$file.namespaces must be a list\n";
            for my $index ( 0 .. $#{$roots} ) {
                push @{ $config{namespaces} },
                  _normalize_namespace( $roots->[$index], "$file.namespaces[$index]" );
            }
            next;
        }

        if ( $kind eq "glab-groups/project-overrides" ) {
            my $projects = $payload->{projects};
            ref($projects) eq "ARRAY" or die "$file.projects must be a list\n";
            for my $index ( 0 .. $#{$projects} ) {
                my $override = _normalize_override( $projects->[$index], "$file.projects[$index]" );
                $config{overrides}->{ $override->{target_project_path} } = $override;
            }
            next;
        }

        if ( $kind eq "glab-groups/project-exclusions" ) {
            my $projects = $payload->{projects};
            ref($projects) eq "ARRAY" or die "$file.projects must be a list\n";
            for my $index ( 0 .. $#{$projects} ) {
                my $item = $projects->[$index];
                ref($item) eq "HASH" or die "$file.projects[$index] must be an object\n";
                my $path = _required_relative_project_path( $item->{target_project_path}, "$file.projects[$index].target_project_path" );
                my $reason = _required_string( $item->{reason} || "Excluded by config", "$file.projects[$index].reason" );
                $config{exclusions}->{$path} = $reason;
            }
            next;
        }

        die "unsupported config kind in $file: $kind\n";
    }

    @{ $config{namespaces} } or die "config dir must contain at least one namespace root\n";
    return \%config;
}

sub resolve_selected_refs {
    my ( $default_branch, $policy, $available ) = @_;

    my @branches;
    my %seen_branches;
    my @tags;
    my %seen_tags;

    if ($default_branch) {
        _push_unique( \@branches, \%seen_branches, $default_branch );
    }
    if ( $policy->{mirror_pristine_tar} && $available->{branches}->{"pristine-tar"} ) {
        _push_unique( \@branches, \%seen_branches, "pristine-tar" );
    }
    for my $spec ( @{ $policy->{additional_branches} || [] } ) {
        my $name = $spec->{name};
        next unless $available->{branches}->{$name};
        _push_unique( \@branches, \%seen_branches, $name );
    }

    if ( $policy->{mirror_pristine_tar} && $available->{tags}->{"pristine-tar"} ) {
        _push_unique( \@tags, \%seen_tags, "pristine-tar" );
    }
    for my $spec ( @{ $policy->{additional_tags} || [] } ) {
        my $name = $spec->{name};
        next unless $available->{tags}->{$name};
        _push_unique( \@tags, \%seen_tags, $name );
    }

    return {
        branches => \@branches,
        tags => \@tags,
    };
}

sub classify_plan_action {
    my ( $source_project, $target_project, $policy, $exclusion_reason ) = @_;
    return "skip" if $exclusion_reason;
    return "fail" if !$source_project || ref($source_project) ne "HASH";
    return "create_project" if !$target_project;

    my $source_visibility = _coalesce_visibility( $policy->{visibility}, $source_project->{visibility} );
    my $source_description = _normalize_description( $source_project->{description} );
    my $target_description = _normalize_description( $target_project->{description} );

    return "update_project"
      if ( ( $target_project->{visibility} || "" ) ne $source_visibility )
      || ( $target_description ne $source_description )
      || ( !!$target_project->{archived} != !!$source_project->{archived} )
      || ( !!$target_project->{lfs_enabled} != !!( $policy->{force_lfs} || $source_project->{lfs_enabled} ) );

    return "mirror_only";
}

sub analyze_selected_refs {
    my ( $repo_dir, $refs, $max_blob_bytes ) = @_;
    my @rev_args = (
        map { "refs/heads/$_" } @{ $refs->{branches} || [] },
        map { "refs/tags/$_" } @{ $refs->{tags} || [] },
    );
    @rev_args or return { total_bytes => 0, oversized_blobs => [] };

    my $rev_result = _run_command(
        [ "git", "-C", $repo_dir, "rev-list", "--objects", @rev_args ],
        {
            timeout => 300,
        }
    );
    $rev_result->{status} == 0 or die "git rev-list failed: $rev_result->{output}\n";

    my %object_ids;
    for my $line ( split /\n/, $rev_result->{output} ) {
        my ($object_id) = split /\s+/, $line;
        next unless $object_id;
        $object_ids{$object_id} = 1;
    }

    return { total_bytes => 0, oversized_blobs => [] } unless %object_ids;

    my ( $fh, $path ) = tempfile();
    print {$fh} join( "\n", sort keys %object_ids ), "\n";
    close $fh;

    my $cmd = join q{ },
      _shell_quote("git"),
      _shell_quote("-C"),
      _shell_quote($repo_dir),
      _shell_quote("cat-file"),
      _shell_quote("--batch-check=%(objectname) %(objecttype) %(objectsize)"),
      "<",
      _shell_quote($path),
      "2>&1";
    my $cat_result = _run_shell_command(
        $cmd,
        {
            timeout => 300,
        }
    );
    unlink $path;
    $cat_result->{status} == 0 or die "git cat-file failed: $cat_result->{output}\n";

    my $total_bytes = 0;
    my @oversized_blobs;
    for my $line ( split /\n/, $cat_result->{output} ) {
        next unless $line =~ /\A([0-9a-f]{40})\s+(\w+)\s+(\d+)\z/;
        my ( $object_id, $type, $size ) = ( $1, $2, $3 + 0 );
        $total_bytes += $size;
        if ( $type eq "blob" && $size > $max_blob_bytes ) {
            push @oversized_blobs, { object_id => $object_id, size => $size };
        }
    }
    return {
        total_bytes => $total_bytes,
        oversized_blobs => \@oversized_blobs,
    };
}

sub _cmd_discover {
    my (@argv) = @_;
    my %opt = ( output => "discover.json" );
    GetOptionsFromArray(
        \@argv,
        "config-dir=s" => \$opt{config_dir},
        "output=s" => \$opt{output},
    ) or die _usage();

    my $config = load_config_dir( $opt{config_dir} );
    my $inventory = _discover_inventory($config);
    _write_json( $opt{output}, $inventory );
    return 0;
}

sub _cmd_normalize {
    my (@argv) = @_;
    my %opt = ( output => "normalized.json" );
    GetOptionsFromArray(
        \@argv,
        "input=s" => \$opt{input},
        "output=s" => \$opt{output},
    ) or die _usage();

    my $inventory = _read_json( $opt{input} );
    $inventory = _normalize_inventory($inventory);
    _write_json( $opt{output}, $inventory );
    return 0;
}

sub _cmd_plan {
    my (@argv) = @_;
    my %opt = (
        batch_size => 25,
        output => "plan.json",
        summary => "plan.md",
    );
    GetOptionsFromArray(
        \@argv,
        "config-dir=s" => \$opt{config_dir},
        "batch-size=i" => \$opt{batch_size},
        "output=s" => \$opt{output},
        "summary=s" => \$opt{summary},
    ) or die _usage();

    my $config = load_config_dir( $opt{config_dir} );
    my $inventory = _discover_inventory($config);
    my $normalized = _normalize_inventory($inventory);
    my $plan = _build_plan( $config, $normalized, $opt{batch_size} );
    _write_json( $opt{output}, $plan );
    _write_text( $opt{summary}, _render_plan_summary($plan) );
    return 0;
}

sub _cmd_prepare_target {
    my (@argv) = @_;
    my %opt = ( output => "prepared.json" );
    GetOptionsFromArray(
        \@argv,
        "plan=s" => \$opt{plan},
        "output=s" => \$opt{output},
    ) or die _usage();

    my $plan = _read_json( $opt{plan} );
    my $client = _load_target_client();
    my @prepared;
    for my $entry ( @{ $plan->{plan} || [] } ) {
        next if $entry->{action} eq "skip" || $entry->{action} eq "fail";
        push @prepared, _ensure_target_project( $client, $entry );
    }
    _write_json(
        $opt{output},
        {
            prepared => \@prepared,
        }
    );
    return 0;
}

sub _cmd_mirror {
    my (@argv) = @_;
    my %opt = (
        output => "results.json",
        jsonl => "results.jsonl",
        batch_size => 25,
        batch_start => 0,
        batch_stride => 1,
        batch_limit => 0,
    );
    GetOptionsFromArray(
        \@argv,
        "plan=s" => \$opt{plan},
        "output=s" => \$opt{output},
        "jsonl=s" => \$opt{jsonl},
        "batch-size=i" => \$opt{batch_size},
        "batch-start=i" => \$opt{batch_start},
        "batch-stride=i" => \$opt{batch_stride},
        "batch-limit=i" => \$opt{batch_limit},
    ) or die _usage();

    $opt{batch_size} > 0 or die "batch-size must be greater than zero\n";
    $opt{batch_start} >= 0 or die "batch-start must be zero or greater\n";
    $opt{batch_stride} > 0 or die "batch-stride must be greater than zero\n";
    $opt{batch_limit} >= 0 or die "batch-limit must be zero or greater\n";

    my $plan = _read_json( $opt{plan} );
    my $target_client = _load_target_client();
    my $source_auth = _load_source_auth();
    my @entries = @{ $plan->{plan} || [] };
    my $total = scalar @entries;
    my $total_batches = _ceil_div( $total, $opt{batch_size} );

    my @results;
    my $processed_batches = 0;
    open( my $jsonl_fh, ">:encoding(UTF-8)", $opt{jsonl} ) or die "unable to write $opt{jsonl}\n";

    for ( my $batch_index = $opt{batch_start}; $batch_index < $total_batches; $batch_index += $opt{batch_stride} ) {
        last if $opt{batch_limit} > 0 && $processed_batches >= $opt{batch_limit};
        my $start = $batch_index * $opt{batch_size};
        my $end = $start + $opt{batch_size} - 1;
        $end = $#entries if $end > $#entries;
        last if $start > $#entries;

        for my $index ( $start .. $end ) {
            my $entry = $entries[$index];
            my $result = eval { _mirror_entry( $target_client, $source_auth, $entry ) };
            if ($@) {
                $result = {
                    target_full_path => $entry->{target_full_path},
                    planned_action => $entry->{action},
                    status => "skipped",
                    reason => "Repository skipped after unrecoverable error.",
                    error => _trim_error($@),
                };
            }
            push @results, $result;
            print {$jsonl_fh} $JSON->encode($result), "\n";
        }
        $processed_batches++;
    }
    close $jsonl_fh;

    my $aggregate = _aggregate_results( \@results );
    _write_json(
        $opt{output},
        {
            batch_size => $opt{batch_size},
            batch_start => $opt{batch_start},
            batch_stride => $opt{batch_stride},
            batch_limit => $opt{batch_limit},
            processed_batches => $processed_batches,
            total_batches => $total_batches,
            counts => $aggregate,
            results => \@results,
        }
    );
    return 0;
}

sub _cmd_verify {
    my (@argv) = @_;
    my %opt = ( output => "verify.json" );
    GetOptionsFromArray(
        \@argv,
        "plan=s" => \$opt{plan},
        "output=s" => \$opt{output},
    ) or die _usage();

    my $plan = _read_json( $opt{plan} );
    my $client = _load_target_client();
    my @results;
    for my $entry ( @{ $plan->{plan} || [] } ) {
        push @results, _verify_entry( $client, $entry );
    }
    _write_json( $opt{output}, { results => \@results } );
    return 0;
}

sub _cmd_report {
    my (@argv) = @_;
    my %opt = (
        output => "report.json",
        summary => "report.md",
    );
    my @result_files;
    GetOptionsFromArray(
        \@argv,
        "plan=s" => \$opt{plan},
        "results=s@" => \@result_files,
        "output=s" => \$opt{output},
        "summary=s" => \$opt{summary},
    ) or die _usage();

    my $plan = _read_json( $opt{plan} );
    @result_files or die "at least one --results file is required\n";

    my @rows;
    for my $file (@result_files) {
        my $results = _read_json($file);
        push @rows, grep { ref($_) eq "HASH" } @{ $results->{results} || [] };
    }
    my $report = {
        generated_at => _timestamp(),
        plan_counts => $plan->{counts},
        result_counts => _aggregate_results( \@rows ),
        results => \@rows,
    };
    _write_json( $opt{output}, $report );
    _write_text( $opt{summary}, _render_report_summary($report) );
    return 0;
}

sub _cmd_resume {
    my (@argv) = @_;
    my %opt = ( output => "resume.json" );
    GetOptionsFromArray(
        \@argv,
        "plan=s" => \$opt{plan},
        "results=s" => \$opt{results},
        "output=s" => \$opt{output},
    ) or die _usage();

    my $plan = _read_json( $opt{plan} );
    my $results = _read_json( $opt{results} );
    my %done = map { ( $_->{target_full_path} => 1 ) } grep { ref($_) eq "HASH" } @{ $results->{results} || [] };
    my @remaining = grep { !$done{ $_->{target_full_path} } } @{ $plan->{plan} || [] };
    _write_json(
        $opt{output},
        {
            remaining => \@remaining,
            remaining_count => scalar @remaining,
        }
    );
    return 0;
}

sub _discover_inventory {
    my ($config) = @_;
    my @inventory;
    for my $namespace ( @{ $config->{namespaces} } ) {
        my ( $base_url, $group_path ) = _parse_group_url( $namespace->{source_group_url} );
        my $source_client = _make_gitlab_client( $base_url, undef, undef );
        my $projects = _list_group_projects( $source_client, $group_path );
        push @inventory,
          {
            namespace => $namespace,
            group_path => $group_path,
            base_url => $base_url,
            projects => $projects,
          };
    }
    return {
        discovered_at => _timestamp(),
        inventory => \@inventory,
    };
}

sub _normalize_inventory {
    my ($inventory) = @_;
    ref($inventory) eq "HASH" or die "inventory must be an object\n";
    my @normalized;
    for my $item ( @{ $inventory->{inventory} || [] } ) {
        my @projects = sort {
            ( $a->{path_with_namespace} || "" ) cmp ( $b->{path_with_namespace} || "" )
        } @{ $item->{projects} || [] };
        push @normalized,
          {
            %{$item},
            projects => \@projects,
          };
    }
    return {
        discovered_at => $inventory->{discovered_at},
        inventory => \@normalized,
    };
}

sub _build_plan {
    my ( $config, $inventory, $batch_size ) = @_;
    my $target_client = _load_target_client();
    my $target_root_path = _load_target_root_group_path();
    my %group_cache;
    my %project_index_cache;
    my @plan;
    my %counts = (
        create_project => 0,
        update_project => 0,
        mirror_only => 0,
        skip => 0,
        fail => 0,
    );

    for my $bucket ( @{ $inventory->{inventory} || [] } ) {
        my $namespace = $bucket->{namespace};
        my $source_group_path = $bucket->{group_path};
        my $target_namespace_root_path = _join_path( $target_root_path, $namespace->{target_namespace_path} );
        my $target_projects_by_path =
          $project_index_cache{$target_namespace_root_path}
          ||= _build_target_project_index( $target_client, $target_namespace_root_path );

        for my $source_project ( @{ $bucket->{projects} || [] } ) {
            my $source_full_path = _required_string( $source_project->{path_with_namespace}, "path_with_namespace" );
            next if $source_full_path eq $source_group_path;
            my $relative_path = _relative_path( $source_group_path, $source_full_path );
            my $target_relative_project_path = _join_path( $namespace->{target_namespace_path}, $relative_path );
            my $target_full_path = _join_path( $target_root_path, $target_relative_project_path );
            my $target_namespace_path = dirname($target_full_path);
            my $override = $config->{overrides}->{$target_relative_project_path} || {};
            my $policy = _merge_policy( $config->{defaults}, $namespace, $override );
            my $target_namespace_id = _ensure_group_path( $target_client, $target_namespace_path, \%group_cache, $policy->{visibility} );
            my $target_project = $target_projects_by_path->{$target_full_path};
            my $skip_reason = $config->{exclusions}->{$target_relative_project_path};
            my $action = classify_plan_action(
                $source_project,
                $target_project,
                $policy,
                $skip_reason,
            );
            $counts{$action}++;
            push @plan,
              {
                action => $action,
                policy => $policy,
                skip_reason => $skip_reason,
                source_archived => !!$source_project->{archived},
                source_default_branch => $source_project->{default_branch},
                source_description => _normalize_description( $source_project->{description} ),
                source_empty_repo => !!$source_project->{empty_repo},
                source_full_path => $source_full_path,
                source_group_path => $source_group_path,
                source_http_url => $source_project->{http_url_to_repo},
                source_lfs_enabled => !!$source_project->{lfs_enabled},
                source_last_activity_at => $source_project->{last_activity_at},
                source_project_id => $source_project->{id},
                source_ssh_url => $source_project->{ssh_url_to_repo},
                source_visibility => $source_project->{visibility},
                target_full_path => $target_full_path,
                target_relative_project_path => $target_relative_project_path,
                target_namespace_id => $target_namespace_id,
                target_namespace_path => $target_namespace_path,
                target_project_id => $target_project ? $target_project->{id} : undef,
                target_visibility => $target_project ? $target_project->{visibility} : undef,
              };
        }
    }

    @plan = sort { $a->{target_full_path} cmp $b->{target_full_path} } @plan;
    return {
        batch_size => $batch_size,
        counts => \%counts,
        generated_at => _timestamp(),
        plan => \@plan,
        total_batches => _ceil_div( scalar @plan, $batch_size ),
        total_targets => scalar @plan,
    };
}

sub _mirror_entry {
    my ( $target_client, $source_auth, $entry ) = @_;
    if ( $entry->{action} eq "skip" ) {
        return {
            target_full_path => $entry->{target_full_path},
            planned_action => $entry->{action},
            status => "skipped",
            reason => $entry->{skip_reason} || "Excluded by config",
        };
    }
    if ( $entry->{action} eq "fail" ) {
        return {
            target_full_path => $entry->{target_full_path},
            planned_action => $entry->{action},
            status => "failed",
            error => "Plan marked target as failed",
        };
    }

    my $prepared = _ensure_target_project( $target_client, $entry );
    if ( $entry->{source_empty_repo} ) {
        my $verified = _verify_entry( $target_client, $entry );
        return {
            target_full_path => $entry->{target_full_path},
            planned_action => $entry->{action},
            status => $prepared->{created} ? "created_empty" : "updated_empty",
            prepared => $prepared,
            verify => $verified,
        };
    }

    my $workdir = tempdir( CLEANUP => 1 );
    my $repo_dir = File::Spec->catdir( $workdir, "repo" );
    _run_command( [ "git", "init", $repo_dir ], { timeout => 120 } );

    my $source_url = _maybe_auth_url( $entry->{source_http_url}, $source_auth->{username}, $source_auth->{token} );
    my $target_url = _maybe_auth_url( _project_git_url( $target_client->{base_url}, $entry->{target_full_path} ), $target_client->{username}, $target_client->{token} );

    _run_command( [ "git", "-C", $repo_dir, "remote", "add", "source", $source_url ], { timeout => 60 } );
    _run_command( [ "git", "-C", $repo_dir, "remote", "add", "target", $target_url ], { timeout => 60 } );

    my $available = _discover_remote_refs( $source_url, $entry->{policy} );
    my $default_branch = $entry->{source_default_branch} || $available->{default_branch} || "";
    my $selected = resolve_selected_refs( $default_branch, $entry->{policy}, $available );
    @{ $selected->{branches} } or die "no source branches resolved for $entry->{source_full_path}\n";

    _fetch_selected_refs( $repo_dir, $selected, $entry->{policy} );
    _run_command( [ "git", "-C", $repo_dir, "checkout", "-f", $selected->{branches}->[0] ], { timeout => 300 } );

    my $size_before = analyze_selected_refs( $repo_dir, $selected, $entry->{policy}->{max_blob_bytes} );
    if ( $size_before->{total_bytes} > $entry->{policy}->{size_limit_bytes} ) {
        return {
            target_full_path => $entry->{target_full_path},
            planned_action => $entry->{action},
            selected_refs => $selected,
            size => $size_before,
            status => "skipped",
            reason => "Repository above permitted size limit.",
        };
    }

    my $lfs_rewrite_attempted = JSON::PP::false;
    my $size_after = $size_before;
    my $lfs_rewrite_error = "";
    if ( @{ $size_before->{oversized_blobs} } && $entry->{policy}->{allow_blob_rewrite} ) {
        $lfs_rewrite_attempted = JSON::PP::true;
        my $ok = eval {
            _rewrite_large_blobs_to_lfs( $repo_dir, $selected, $entry->{policy}->{max_blob_bytes}, $entry->{policy} );
            1;
        };
        if ($ok) {
            $size_after = analyze_selected_refs( $repo_dir, $selected, $entry->{policy}->{max_blob_bytes} );
        }
        else {
            $lfs_rewrite_error = _trim_error($@);
        }
    }
    if ( @{ $size_after->{oversized_blobs} } || $lfs_rewrite_error ) {
        return {
            target_full_path => $entry->{target_full_path},
            planned_action => $entry->{action},
            selected_refs => $selected,
            size => $size_after,
            lfs_rewrite_attempted => $lfs_rewrite_attempted,
            status => "skipped",
            reason => "Large blobs exceed 100 MiB and could not be remediated.",
            error => $lfs_rewrite_error,
        };
    }

    my $needs_lfs = $entry->{policy}->{force_lfs} || $entry->{source_lfs_enabled} || _repo_has_lfs_files($repo_dir);
    if ($needs_lfs) {
        _prepare_lfs( $repo_dir, $entry->{policy} );
        for my $branch ( @{ $selected->{branches} || [] } ) {
            _run_command(
                [ "git", "-C", $repo_dir, "lfs", "fetch", "source", "refs/heads/$branch" ],
                _git_command_options( $entry->{policy}, JSON::PP::true )
            );
        }
        for my $tag ( @{ $selected->{tags} || [] } ) {
            _run_command(
                [ "git", "-C", $repo_dir, "lfs", "fetch", "source", "refs/tags/$tag" ],
                _git_command_options( $entry->{policy}, JSON::PP::true )
            );
        }
        _run_command(
            [ "git", "-C", $repo_dir, "lfs", "push", "--all", "target" ],
            _git_command_options( $entry->{policy}, JSON::PP::true )
        );
    }

    _push_selected_refs( $repo_dir, $selected, $entry->{policy} );
    _finalize_target_project( $target_client, $prepared->{project_id}, $default_branch, $entry );
    my $verified = _verify_entry( $target_client, $entry, $selected );

    return {
        target_full_path => $entry->{target_full_path},
        planned_action => $entry->{action},
        prepared => $prepared,
        selected_refs => $selected,
        size => $size_after,
        needs_lfs => $needs_lfs ? JSON::PP::true : JSON::PP::false,
        lfs_rewrite_attempted => $lfs_rewrite_attempted,
        status => "mirrored",
        verify => $verified,
    };
}

sub _verify_entry {
    my ( $target_client, $entry, $selected ) = @_;
    my $project = _get_project( $target_client, $entry->{target_full_path} );
    return {
        target_full_path => $entry->{target_full_path},
        exists => $project ? JSON::PP::true : JSON::PP::false,
    } unless $project;

    my %branches;
    my %tags;
    if ($selected) {
        for my $branch ( @{ $selected->{branches} || [] } ) {
            $branches{$branch} = _get_branch( $target_client, $project->{id}, $branch ) ? JSON::PP::true : JSON::PP::false;
        }
        for my $tag ( @{ $selected->{tags} || [] } ) {
            $tags{$tag} = _get_tag( $target_client, $project->{id}, $tag ) ? JSON::PP::true : JSON::PP::false;
        }
    }

    return {
        target_full_path => $entry->{target_full_path},
        default_branch => $project->{default_branch},
        exists => JSON::PP::true,
        branches => \%branches,
        tags => \%tags,
    };
}

sub _aggregate_results {
    my ($results) = @_;
    my %counts = (
        failed => 0,
        mirrored => 0,
        skipped => 0,
        updated_empty => 0,
        created_empty => 0,
    );
    for my $result ( @{$results} ) {
        my $status = $result->{status} || "unknown";
        $counts{$status}++ if exists $counts{$status};
    }
    return \%counts;
}

sub _render_plan_summary {
    my ($plan) = @_;
    return join(
        "",
        "## Group mirror plan\n\n",
        "- generated at: $plan->{generated_at}\n",
        "- total targets: $plan->{total_targets}\n",
        "- batch size: $plan->{batch_size}\n",
        "- total batches: $plan->{total_batches}\n",
        "- create project: $plan->{counts}->{create_project}\n",
        "- update project: $plan->{counts}->{update_project}\n",
        "- mirror only: $plan->{counts}->{mirror_only}\n",
        "- skip: $plan->{counts}->{skip}\n",
        "- fail: $plan->{counts}->{fail}\n",
    );
}

sub _render_report_summary {
    my ($report) = @_;
    my $counts = $report->{result_counts} || {};
    my @failed = grep { ( $_->{status} || "" ) eq "failed" } @{ $report->{results} || [] };
    my @skipped = grep { ( $_->{status} || "" ) eq "skipped" } @{ $report->{results} || [] };

    my $text = join(
        "",
        "## Group mirror report\n\n",
        "- generated at: $report->{generated_at}\n",
        "- mirrored: ", ( $counts->{mirrored} || 0 ), "\n",
        "- created empty: ", ( $counts->{created_empty} || 0 ), "\n",
        "- updated empty: ", ( $counts->{updated_empty} || 0 ), "\n",
        "- skipped: ", ( $counts->{skipped} || 0 ), "\n",
        "- failed: ", ( $counts->{failed} || 0 ), "\n\n",
    );
    if (@skipped) {
        $text .= "### Skipped\n\n";
        for my $item (@skipped) {
            $text .= "- `$item->{target_full_path}`: " . ( $item->{reason} || "skipped" ) . "\n";
        }
        $text .= "\n";
    }
    if (@failed) {
        $text .= "### Failed\n\n";
        for my $item (@failed) {
            $text .= "- `$item->{target_full_path}`: " . ( $item->{error} || "failed" ) . "\n";
        }
        $text .= "\n";
    }
    return $text;
}

sub _normalize_defaults_payload {
    my ( $payload, $label ) = @_;
    ref($payload) eq "HASH" or die "$label.defaults must be an object\n";
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.defaults.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.defaults.additional_tags" ),
        allow_blob_rewrite => _bool_or_default( $payload->{allow_blob_rewrite}, 1 ),
        batch_size => _defaulted_positive_int( $payload->{batch_size}, $DEFAULTS{batch_size}, "$label.defaults.batch_size" ),
        force_lfs => _bool_or_default( $payload->{force_lfs}, 0 ),
        git_timeout_seconds => _defaulted_positive_int( $payload->{git_timeout_seconds}, $DEFAULTS{git_timeout_seconds}, "$label.defaults.git_timeout_seconds" ),
        max_blob_bytes => _defaulted_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.defaults.max_blob_bytes" ),
        mirror_pristine_tar => _bool_or_default( $payload->{mirror_pristine_tar}, 1 ),
        retry_attempts => _defaulted_positive_int( $payload->{retry_attempts}, $DEFAULTS{retry_attempts}, "$label.defaults.retry_attempts" ),
        retry_backoff_seconds => _defaulted_positive_int( $payload->{retry_backoff_seconds}, $DEFAULTS{retry_backoff_seconds}, "$label.defaults.retry_backoff_seconds" ),
        size_limit_bytes => _defaulted_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.defaults.size_limit_bytes" ),
        visibility => _coalesce_visibility( $payload->{visibility}, $DEFAULTS{visibility} ),
    };
}

sub _normalize_namespace {
    my ( $payload, $label ) = @_;
    ref($payload) eq "HASH" or die "$label must be an object\n";
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.additional_tags" ),
        allow_blob_rewrite => _optional_bool( $payload->{allow_blob_rewrite} ),
        force_lfs => _optional_bool( $payload->{force_lfs} ),
        git_timeout_seconds => $payload->{git_timeout_seconds},
        mirror_pristine_tar => _optional_bool( $payload->{mirror_pristine_tar} ),
        name => _required_string( $payload->{name}, "$label.name" ),
        retry_attempts => _optional_positive_int( $payload->{retry_attempts}, "$label.retry_attempts" ),
        retry_backoff_seconds => _optional_positive_int( $payload->{retry_backoff_seconds}, "$label.retry_backoff_seconds" ),
        size_limit_bytes => _optional_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.size_limit_bytes" ),
        max_blob_bytes => _optional_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.max_blob_bytes" ),
        source_group_url => _required_https_url( $payload->{source_group_url}, "$label.source_group_url" ),
        target_namespace_path => _required_relative_namespace_path( $payload->{target_namespace_path}, "$label.target_namespace_path" ),
        visibility => defined $payload->{visibility}
          ? _coalesce_visibility( $payload->{visibility}, $DEFAULTS{visibility} )
          : undef,
    };
}

sub _normalize_override {
    my ( $payload, $label ) = @_;
    ref($payload) eq "HASH" or die "$label must be an object\n";
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.additional_tags" ),
        allow_blob_rewrite => _optional_bool( $payload->{allow_blob_rewrite} ),
        force_lfs => _optional_bool( $payload->{force_lfs} ),
        git_timeout_seconds => $payload->{git_timeout_seconds},
        mirror_pristine_tar => _optional_bool( $payload->{mirror_pristine_tar} ),
        retry_attempts => _optional_positive_int( $payload->{retry_attempts}, "$label.retry_attempts" ),
        retry_backoff_seconds => _optional_positive_int( $payload->{retry_backoff_seconds}, "$label.retry_backoff_seconds" ),
        size_limit_bytes => _optional_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.size_limit_bytes" ),
        max_blob_bytes => _optional_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.max_blob_bytes" ),
        target_project_path => _required_relative_project_path( $payload->{target_project_path}, "$label.target_project_path" ),
        visibility => $payload->{visibility} ? _coalesce_visibility( $payload->{visibility}, $DEFAULTS{visibility} ) : undef,
    };
}

sub _merge_policy {
    my ( $defaults, $namespace, $override ) = @_;
    my $policy = { %{$defaults} };
    for my $overlay ( $namespace, $override ) {
        next unless ref($overlay) eq "HASH";
        for my $key (qw(
          allow_blob_rewrite
          force_lfs
          git_timeout_seconds
          max_blob_bytes
          mirror_pristine_tar
          retry_attempts
          retry_backoff_seconds
          size_limit_bytes
          visibility
        )) {
            next unless exists $overlay->{$key};
            next unless defined $overlay->{$key};
            $policy->{$key} = $overlay->{$key};
        }
    }
    $policy->{additional_branches} = [
        @{ $defaults->{additional_branches} || [] },
        @{ $namespace->{additional_branches} || [] },
        @{ $override->{additional_branches} || [] },
    ];
    $policy->{additional_tags} = [
        @{ $defaults->{additional_tags} || [] },
        @{ $namespace->{additional_tags} || [] },
        @{ $override->{additional_tags} || [] },
    ];
    $policy->{git_timeout_seconds} ||= $DEFAULTS{git_timeout_seconds};
    $policy->{retry_attempts} ||= $DEFAULTS{retry_attempts};
    $policy->{retry_backoff_seconds} ||= $DEFAULTS{retry_backoff_seconds};
    $policy->{size_limit_bytes} ||= $DEFAULTS{size_limit_bytes};
    $policy->{max_blob_bytes} ||= $DEFAULTS{max_blob_bytes};
    $policy->{visibility} = $DEFAULTS{visibility} unless defined $policy->{visibility};
    return $policy;
}

sub _load_target_client {
    return _make_gitlab_client(
        _required_https_url( _required_env_file("GL_BASE_URL"), "GL_BASE_URL" ),
        _required_env_file("GL_BRIDGE_FORK_USER_GLAB"),
        _required_env_file("GL_PAT_FORK_GLAB_SVC"),
    );
}

sub _load_target_root_group_path {
    return _required_group_path_min_segments( _required_env_file("GL_GROUP_TOP_GLAB_OWNER"), "GL_GROUP_TOP_GLAB_OWNER", 1 );
}

sub _load_source_auth {
    my $username = _optional_env_file("GL_GROUPS_SOURCE_USERNAME");
    my $token = _optional_env_file("GL_GROUPS_SOURCE_TOKEN");
    return { username => $username, token => $token };
}

sub _make_gitlab_client {
    my ( $base_url, $username, $token ) = @_;
    return {
        base_url => $base_url,
        token => $token,
        username => $username,
    };
}

sub _ensure_group_path {
    my ( $client, $group_path, $cache, $visibility ) = @_;
    return $cache->{$group_path} if exists $cache->{$group_path};
    my @parts = split m{/}, $group_path;
    my $current = "";
    my $parent_id;
    for my $part (@parts) {
        $current = $current ? "$current/$part" : $part;
        if ( exists $cache->{$current} ) {
            $parent_id = $cache->{$current};
            next;
        }
        my $group = _get_group( $client, $current );
        if ( !$group ) {
            my %payload = (
                name => $part,
                path => $part,
                visibility => $visibility,
            );
            $payload{parent_id} = $parent_id if defined $parent_id;
            $group = _gitlab_request( $client, "POST", "/groups", \%payload );
        }
        $parent_id = $group->{id};
        $cache->{$current} = $parent_id;
    }
    return $cache->{$group_path};
}

sub _ensure_target_project {
    my ( $client, $entry ) = @_;
    my $existing = _get_project( $client, $entry->{target_full_path} );
    my $name = basename( $entry->{target_full_path} );
    my %payload = (
        description => $entry->{source_description},
        lfs_enabled => $entry->{policy}->{force_lfs} || $entry->{source_lfs_enabled} ? JSON::PP::true : JSON::PP::false,
        visibility => $entry->{policy}->{visibility},
    );

    my $project;
    my $created = JSON::PP::false;
    my $updated = JSON::PP::false;
    if ( !$existing ) {
        $project = _gitlab_request(
            $client,
            "POST",
            "/projects",
            {
                %payload,
                name => $name,
                namespace_id => $entry->{target_namespace_id},
                path => $name,
            }
        );
        $created = JSON::PP::true;
    }
    else {
        $project = $existing;
        my $needs_update =
             ( $project->{visibility} || "" ) ne $payload{visibility}
          || _normalize_description( $project->{description} ) ne $payload{description}
          || !!$project->{lfs_enabled} != !!$payload{lfs_enabled};
        if ($needs_update) {
            $project = _gitlab_request( $client, "PUT", "/projects/" . $project->{id}, \%payload );
            $updated = JSON::PP::true;
        }
    }

    if ( $entry->{source_archived} && !$project->{archived} ) {
        _gitlab_request( $client, "POST", "/projects/" . $project->{id} . "/archive", undef );
    }
    if ( !$entry->{source_archived} && $project->{archived} ) {
        _gitlab_request( $client, "POST", "/projects/" . $project->{id} . "/unarchive", undef );
    }

    return {
        created => $created,
        project_id => $project->{id},
        updated => $updated,
    };
}

sub _finalize_target_project {
    my ( $client, $project_id, $default_branch, $entry ) = @_;
    if ($default_branch) {
        _gitlab_request(
            $client,
            "PUT",
            "/projects/$project_id",
            {
                default_branch => $default_branch,
                description => $entry->{source_description},
                visibility => $entry->{policy}->{visibility},
            }
        );
    }
}

sub _get_group {
    my ( $client, $group_path ) = @_;
    return _gitlab_request( $client, "GET", "/groups/" . _encode_path($group_path), undef, { allow_missing => 1 } );
}

sub _get_project {
    my ( $client, $project_path ) = @_;
    return _gitlab_request( $client, "GET", "/projects/" . _encode_path($project_path), undef, { allow_missing => 1 } );
}

sub _get_branch {
    my ( $client, $project_id, $branch_name ) = @_;
    return _gitlab_request(
        $client,
        "GET",
        "/projects/$project_id/repository/branches/" . _encode_path($branch_name),
        undef,
        { allow_missing => 1 }
    );
}

sub _get_tag {
    my ( $client, $project_id, $tag_name ) = @_;
    return _gitlab_request(
        $client,
        "GET",
        "/projects/$project_id/repository/tags/" . _encode_path($tag_name),
        undef,
        { allow_missing => 1 }
    );
}

sub _list_group_projects {
    my ( $client, $group_path ) = @_;
    my @projects;
    my $page = 1;
    while (1) {
        my $path = sprintf(
            "/groups/%s/projects?include_subgroups=true&with_shared=false&per_page=100&page=%d",
            _encode_path($group_path),
            $page,
        );
        my $data = _gitlab_request( $client, "GET", $path, undef );
        ref($data) eq "ARRAY" or die "group projects response must be a list\n";
        last unless @{$data};
        push @projects, @{$data};
        last if @{$data} < 100;
        $page++;
    }
    return \@projects;
}

sub _build_target_project_index {
    my ( $client, $group_path ) = @_;
    my $group = _get_group( $client, $group_path );
    return {} unless $group;

    my %index;
    for my $project ( @{ _list_group_projects( $client, $group_path ) } ) {
        next unless ref($project) eq "HASH";
        my $path = $project->{path_with_namespace};
        next unless defined $path && !ref($path) && length $path;
        $index{$path} = $project;
    }
    return \%index;
}

sub _discover_remote_refs {
    my ( $source_url, $policy ) = @_;
    my $result = _run_command(
        [ "git", "ls-remote", "--heads", "--tags", "--symref", $source_url ],
        _git_command_options( $policy, JSON::PP::true )
    );
    $result->{status} == 0 or die "git ls-remote failed: $result->{output}\n";

    my %branches;
    my %tags;
    my $default_branch = "";
    for my $line ( split /\n/, $result->{output} ) {
        next unless $line;
        if ( $line =~ /\Aref:\s+refs\/heads\/([^\s]+)\s+HEAD\z/ ) {
            $default_branch = $1;
            next;
        }
        if ( $line =~ /\A[0-9a-f]{40}\s+refs\/heads\/(.+)\z/ ) {
            $branches{$1} = 1;
            next;
        }
        if ( $line =~ /\A[0-9a-f]{40}\s+refs\/tags\/(.+?)(?:\^\{\})?\z/ ) {
            $tags{$1} = 1;
            next;
        }
    }
    return {
        branches => \%branches,
        default_branch => $default_branch,
        tags => \%tags,
    };
}

sub _fetch_selected_refs {
    my ( $repo_dir, $selected, $policy ) = @_;
    for my $branch ( @{ $selected->{branches} || [] } ) {
        _run_command(
            [
                "git", "-C", $repo_dir, "fetch", "--no-tags", "source",
                "+refs/heads/$branch:refs/heads/$branch"
            ],
            _git_command_options( $policy, JSON::PP::true )
        );
    }
    for my $tag ( @{ $selected->{tags} || [] } ) {
        _run_command(
            [
                "git", "-C", $repo_dir, "fetch", "--no-tags", "source",
                "+refs/tags/$tag:refs/tags/$tag"
            ],
            _git_command_options( $policy, JSON::PP::true )
        );
    }
}

sub _push_selected_refs {
    my ( $repo_dir, $selected, $policy ) = @_;
    for my $branch ( @{ $selected->{branches} || [] } ) {
        my $result = _run_command(
            [
                "git", "-C", $repo_dir, "push", "--force", "target",
                "refs/heads/$branch:refs/heads/$branch"
            ],
            _git_command_options( $policy, JSON::PP::true )
        );
        if ( $result->{status} != 0 && $result->{output} =~ /LFS objects are missing/i ) {
            _run_command(
                [ "git", "-C", $repo_dir, "lfs", "push", "--all", "target" ],
                _git_command_options( $policy, JSON::PP::true )
            );
            $result = _run_command(
                [
                    "git", "-C", $repo_dir, "push", "--force", "target",
                    "refs/heads/$branch:refs/heads/$branch"
                ],
                _git_command_options( $policy, JSON::PP::true )
            );
        }
        $result->{status} == 0 or die "git push failed for branch $branch: $result->{output}\n";
    }
    for my $tag ( @{ $selected->{tags} || [] } ) {
        my $result = _run_command(
            [
                "git", "-C", $repo_dir, "push", "--force", "target",
                "refs/tags/$tag:refs/tags/$tag"
            ],
            _git_command_options( $policy, JSON::PP::true )
        );
        if ( $result->{status} != 0 && $result->{output} =~ /LFS objects are missing/i ) {
            _run_command(
                [ "git", "-C", $repo_dir, "lfs", "push", "--all", "target" ],
                _git_command_options( $policy, JSON::PP::true )
            );
            $result = _run_command(
                [
                    "git", "-C", $repo_dir, "push", "--force", "target",
                    "refs/tags/$tag:refs/tags/$tag"
                ],
                _git_command_options( $policy, JSON::PP::true )
            );
        }
        $result->{status} == 0 or die "git push failed for tag $tag: $result->{output}\n";
    }
}

sub _prepare_lfs {
    my ( $repo_dir, $policy ) = @_;
    _run_command( [ "git", "-C", $repo_dir, "lfs", "install", "--local" ], _git_command_options( $policy, JSON::PP::false ) );
}

sub _rewrite_large_blobs_to_lfs {
    my ( $repo_dir, $selected, $max_blob_bytes, $policy ) = @_;
    my @cmd = (
        "git", "-C", $repo_dir, "lfs", "migrate", "import",
        "--above", $max_blob_bytes . "B",
    );
    for my $branch ( @{ $selected->{branches} || [] } ) {
        push @cmd, "--include-ref", "refs/heads/$branch";
    }
    for my $tag ( @{ $selected->{tags} || [] } ) {
        push @cmd, "--include-ref", "refs/tags/$tag";
    }
    my $result = _run_command( \@cmd, _git_command_options( $policy, JSON::PP::true ) );
    $result->{status} == 0 or die "git lfs migrate failed: $result->{output}\n";
}

sub _repo_has_lfs_files {
    my ($repo_dir) = @_;
    my $result = _run_command( [ "git", "-C", $repo_dir, "lfs", "ls-files" ], { timeout => 120 } );
    return 0 if $result->{status} != 0;
    return $result->{output} =~ /\S/ ? 1 : 0;
}

sub _gitlab_request {
    my ( $client, $method, $path, $payload, $opt ) = @_;
    $opt ||= {};
    my $url = $client->{base_url} . "/api/v4" . $path;
    my $attempts = $DEFAULTS{retry_attempts};
    my $backoff = $DEFAULTS{retry_backoff_seconds};
    my $content = defined $payload ? $JSON->encode($payload) : undef;
    for my $attempt ( 1 .. $attempts ) {
        my @command = (
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--max-time",
            "60",
            "--request",
            $method,
            "--header",
            "Content-Type: application/json",
            "--write-out",
            "\n%{http_code}",
            $url,
        );
        if ( $client->{token} ) {
            push @command, "--header", "PRIVATE-TOKEN: $client->{token}";
        }
        if ( defined $content ) {
            push @command, "--data", $content;
        }

        my $response = _run_command(
            \@command,
            {
                timeout => 90,
            }
        );

        my ( $http_status, $body ) = _split_curl_response( $response->{output} );
        if ( $response->{status} == 0 && $http_status >= 200 && $http_status < 300 ) {
            return undef if !defined $body || $body eq q{};
            return _decode_json_response( $body, $method, $path );
        }
        return undef if $opt->{allow_missing} && $http_status == 404;

        if (
            (
                $response->{status} != 0
                || $http_status == 429
                || $http_status >= 500
            )
            && $attempt < $attempts
          )
        {
            sleep( $backoff * $attempt );
            next;
        }

        my $status_label = $http_status || $response->{status};
        my $message = defined $body && length $body ? $body : ( $response->{output} || "unknown error" );
        die "gitlab request failed [$status_label] $method $path: $message\n";
    }
    die "gitlab request exhausted retries for $method $path\n";
}

sub _split_curl_response {
    my ($text) = @_;
    defined $text or return ( 0, q{} );
    if ( $text =~ /\n(\d{3})\s*\z/s ) {
        my $status = 0 + $1;
        my $body = substr( $text, 0, length($text) - length($1) - 1 );
        $body =~ s/\s+\z//;
        return ( $status, $body );
    }
    return ( 0, $text );
}

sub _decode_json_response {
    my ( $text, $method, $path ) = @_;
    return undef if !defined $text || $text eq q{};
    return $JSON->decode($text);
}

sub _required_env_file {
    my ($name) = @_;
    my $path = $ENV{"${name}_FILE"} || "";
    $path or die "missing required env file variable: ${name}_FILE\n";
    open( my $fh, "<:encoding(UTF-8)", $path ) or die "unable to read $path\n";
    my $value = do { local $/; <$fh> };
    close $fh;
    defined $value or die "empty env file: $path\n";
    $value =~ s/\A\s+//;
    $value =~ s/\s+\z//;
    length $value or die "empty env file: $path\n";
    return $value;
}

sub _optional_env_file {
    my ($name) = @_;
    my $path = $ENV{"${name}_FILE"} || "";
    return undef unless $path;
    open( my $fh, "<:encoding(UTF-8)", $path ) or die "unable to read $path\n";
    my $value = do { local $/; <$fh> };
    close $fh;
    return undef unless defined $value;
    $value =~ s/\A\s+//;
    $value =~ s/\s+\z//;
    return length $value ? $value : undef;
}

sub _read_json {
    my ($path) = @_;
    open( my $fh, "<:encoding(UTF-8)", $path ) or die "unable to read $path\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    return $JSON->decode($text);
}

sub _write_json {
    my ( $path, $payload ) = @_;
    _write_text( $path, JSON::PP->new->canonical(1)->utf8(1)->pretty(1)->encode($payload) );
}

sub _write_text {
    my ( $path, $text ) = @_;
    my $dir = dirname($path);
    make_path($dir) if $dir && !-d $dir;
    open( my $fh, ">:encoding(UTF-8)", $path ) or die "unable to write $path\n";
    print {$fh} $text;
    close $fh;
}

sub _required_string {
    my ( $value, $label ) = @_;
    defined $value or die "$label is required\n";
    ref($value) and die "$label must be a string\n";
    $value =~ s/\A\s+// if !ref($value);
    $value =~ s/\s+\z// if !ref($value);
    length $value or die "$label must not be empty\n";
    return $value;
}

sub _required_project_path {
    my ( $value, $label ) = @_;
    return _required_group_path_min_segments( $value, $label, 2 );
}

sub _required_relative_namespace_path {
    my ( $value, $label ) = @_;
    return _required_group_path_min_segments( $value, $label, 1 );
}

sub _required_relative_project_path {
    my ( $value, $label ) = @_;
    return _required_group_path_min_segments( $value, $label, 2 );
}

sub _required_group_path_min_segments {
    my ( $value, $label, $minimum_segments ) = @_;
    $value = _required_string( $value, $label );
    my @segments = split m{/}, $value;
    @segments >= $minimum_segments
      or die "$label must contain at least $minimum_segments path segment(s)\n";
    $value =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*(?:\/[A-Za-z0-9][A-Za-z0-9._-]*)*\z/
      or die "$label must be a namespace path\n";
    return $value;
}

sub _required_https_url {
    my ( $value, $label ) = @_;
    $value = _required_string( $value, $label );
    $value =~ /\Ahttps:\/\/[A-Za-z0-9.-]+(?::\d+)?(?:\/[^?#]+)?\z/
      or die "$label must be an https URL without query or fragment\n";
    return $value;
}

sub _positive_int {
    my ( $value, $label ) = @_;
    defined $value or die "$label is required\n";
    $value =~ /\A\d+\z/ or die "$label must be a positive integer\n";
    $value > 0 or die "$label must be greater than zero\n";
    return 0 + $value;
}

sub _optional_positive_int {
    my ( $value, $label ) = @_;
    return undef unless defined $value;
    return _positive_int( $value, $label );
}

sub _defaulted_positive_int {
    my ( $value, $default, $label ) = @_;
    return _positive_int( defined $value ? $value : $default, $label );
}

sub _optional_bounded_positive_int {
    my ( $value, $maximum, $label ) = @_;
    return undef unless defined $value;
    my $resolved = _positive_int( $value, $label );
    $resolved <= $maximum or die "$label must be less than or equal to $maximum\n";
    return $resolved;
}

sub _defaulted_bounded_positive_int {
    my ( $value, $default, $maximum, $label ) = @_;
    my $resolved = _defaulted_positive_int( $value, $default, $label );
    $resolved <= $maximum or die "$label must be less than or equal to $maximum\n";
    return $resolved;
}

sub _bool_or_default {
    my ( $value, $default ) = @_;
    return $default ? JSON::PP::true : JSON::PP::false if !defined $value;
    return $value ? JSON::PP::true : JSON::PP::false;
}

sub _optional_bool {
    my ($value) = @_;
    return undef if !defined $value;
    return $value ? JSON::PP::true : JSON::PP::false;
}

sub _coalesce_visibility {
    my ( $value, $default ) = @_;
    my $resolved = defined $value && length $value ? $value : $default;
    $resolved =~ /\A(?:private|internal|public)\z/ or die "invalid visibility: $resolved\n";
    return $resolved;
}

sub _normalize_ref_specs {
    my ( $value, $label ) = @_;
    return [] unless defined $value;
    ref($value) eq "ARRAY" or die "$label must be a list\n";
    my @items;
    my %seen;
    for my $index ( 0 .. $#{$value} ) {
        my $item = $value->[$index];
        my $name;
        if ( !ref($item) ) {
            $name = $item;
        }
        elsif ( ref($item) eq "HASH" ) {
            $name = $item->{name};
        }
        else {
            die "$label\[$index] must be a string or object\n";
        }
        $name = _required_string( $name, "$label\[$index].name" );
        $name =~ /\A[0-9A-Za-z._\/-]+\z/ or die "$label\[$index].name contains invalid characters\n";
        next if $seen{$name}++;
        push @items, { name => $name };
    }
    return \@items;
}

sub _relative_path {
    my ( $prefix, $path ) = @_;
    my $normalized_prefix = $prefix . "/";
    index( $path, $normalized_prefix ) == 0
      or die "source project path is outside configured group: $path\n";
    my $relative = substr( $path, length($normalized_prefix) );
    $relative =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*(?:\/[A-Za-z0-9][A-Za-z0-9._-]*)*\z/
      or die "invalid relative project path: $relative\n";
    return $relative;
}

sub _join_path {
    my ( $left, $right ) = @_;
    return $left . "/" . $right;
}

sub _parse_group_url {
    my ($url) = @_;
    $url =~ /\A(https:\/\/[A-Za-z0-9.-]+(?::\d+)?)(\/.+)\z/ or die "invalid group URL: $url\n";
    my $base = $1;
    my $path = $2;
    $path =~ s{\A/}{};
    $path =~ s{/\z}{};
    $path =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*(?:\/[A-Za-z0-9][A-Za-z0-9._-]*)*\z/
      or die "invalid group URL path: $url\n";
    return ( $base, $path );
}

sub _project_git_url {
    my ( $base_url, $project_path ) = @_;
    return $base_url . "/" . $project_path . ".git";
}

sub _maybe_auth_url {
    my ( $url, $username, $token ) = @_;
    return $url unless $username && $token;
    $url =~ /\Ahttps:\/\/([^\/]+)(\/.*)\z/ or return $url;
    return "https://" . uri_escape_utf8($username) . ":" . uri_escape_utf8($token) . "\@$1$2";
}

sub _encode_path {
    my ($value) = @_;
    return uri_escape_utf8($value);
}

sub _timestamp {
    return strftime( "%Y-%m-%dT%H:%M:%SZ", gmtime() );
}

sub _normalize_description {
    my ($value) = @_;
    return "" unless defined $value;
    $value =~ s/\r\n/\n/g;
    return $value;
}

sub _ceil_div {
    my ( $left, $right ) = @_;
    return 0 if !$left;
    return int( ( $left + $right - 1 ) / $right );
}

sub _push_unique {
    my ( $list, $seen, $value ) = @_;
    return if $seen->{$value}++;
    push @{$list}, $value;
}

sub _trim_error {
    my ($error) = @_;
    $error =~ s/\s+\z//;
    return $error;
}

sub _run_command {
    my ( $args, $opt ) = @_;
    $opt ||= {};
    my $timeout = $opt->{timeout} || 300;
    my $attempts = $opt->{retryable} ? ( $opt->{retry_attempts} || $DEFAULTS{retry_attempts} ) : 1;
    my $backoff = $opt->{retry_backoff_seconds} || $DEFAULTS{retry_backoff_seconds};

    my $command = join q{ }, map { _shell_quote($_) } @{$args};
    my $wrapped = "timeout --signal=KILL ${timeout}s $command 2>&1";

    my $last_result;
    for my $attempt ( 1 .. $attempts ) {
        my $output = qx{$wrapped};
        my $status = $? >> 8;
        my $result = { output => $output, status => $status };
        $last_result = $result;
        return $result if $status == 0;
        last unless _is_retryable_git_error($output) && $attempt < $attempts;
        sleep( $backoff * $attempt );
    }
    return $last_result;
}

sub _git_command_options {
    my ( $policy, $retryable ) = @_;
    $policy ||= {};
    my %opt = (
        timeout => $policy->{git_timeout_seconds} || $DEFAULTS{git_timeout_seconds},
    );
    if ($retryable) {
        $opt{retryable} = 1;
        $opt{retry_attempts} = $policy->{retry_attempts} || $DEFAULTS{retry_attempts};
        $opt{retry_backoff_seconds} = $policy->{retry_backoff_seconds} || $DEFAULTS{retry_backoff_seconds};
    }
    return \%opt;
}

sub _run_shell_command {
    my ( $command, $opt ) = @_;
    $opt ||= {};
    my $timeout = $opt->{timeout} || 300;
    my $wrapped = "timeout --signal=KILL ${timeout}s sh -lc " . _shell_quote($command);
    my $output = qx{$wrapped 2>&1};
    my $status = $? >> 8;
    return { output => $output, status => $status };
}

sub _is_retryable_git_error {
    my ($text) = @_;
    return 1 if $text =~ /timed out/i;
    return 1 if $text =~ /connection reset/i;
    return 1 if $text =~ /TLS/i;
    return 1 if $text =~ /temporarily unavailable/i;
    return 1 if $text =~ /internal server error/i;
    return 1 if $text =~ /remote end hung up unexpectedly/i;
    return 0;
}

sub _shell_quote {
    my ($value) = @_;
    $value = "" unless defined $value;
    $value =~ s/'/'"'"'/g;
    return "'$value'";
}

1;
