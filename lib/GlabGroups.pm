package GlabGroups;

use strict;
use warnings;

use CPAN::Meta::YAML ();
use Exporter qw(import);
use File::Basename qw(dirname basename);
use File::Path qw(make_path);
use File::Spec;
use File::Temp qw(tempdir tempfile);
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;
use MIME::Base64 qw(decode_base64 encode_base64);
use POSIX qw(strftime);
use Time::HiRes qw(sleep);
use Time::Piece ();
use URI::Escape qw(uri_escape_utf8);

use GlabGroups::Source qw(
  _extract_root_repo_path
  _fallback_clone_url
  _parse_source_project_url
  _parse_source_url
  _project_git_url
);

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
    batch_size => 10,
    force_lfs => JSON::PP::false,
    git_timeout_seconds => 1800,
    max_blob_bytes => 100 * 1024 * 1024,
    max_parallel => 10,
    mirror_pristine_tar => JSON::PP::true,
    retry_attempts => 3,
    retry_backoff_seconds => 2,
    size_limit_bytes => 9 * 1024 * 1024 * 1024,
);

my %GITLAB_READ_DEFAULTS = (
    max_time_seconds => 120,
    page_size => 100,
    retry_attempts => 6,
    retry_backoff_seconds => 5,
    timeout_seconds => 150,
);

my $GROUP_PROJECT_CREATION_LEVEL = "maintainer";
my $GROUP_SHARED_RUNNERS_SETTING = "disabled_and_unoverridable";
my $GROUP_SUBGROUP_CREATION_LEVEL = "maintainer";
my $TARGET_SYNC_BRANCH = "gitlab/mcr/main";
my $TARGET_DEFAULT_BRANCH = "mcr/main";

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
    my @files = sort grep { /\.(?:json|ya?ml)\z/ && -f File::Spec->catfile( $config_dir, $_ ) } readdir($dh);
    closedir($dh);

    my %config = (
        defaults => {
            %DEFAULTS,
            additional_branches => [],
            additional_tags => [],
            target_branches_protect => [],
        },
        namespaces => [],
        projects => [],
        exclusions => {},
    );

    for my $file (@files) {
        my $payload = _read_config_payload( File::Spec->catfile( $config_dir, $file ) );
        if ( ref($payload) eq "ARRAY" ) {
            if ( $file =~ /\Aprojects\.ya?ml\z/ ) {
                for my $index ( 0 .. $#{$payload} ) {
                    push @{ $config{projects} },
                      _normalize_project( $payload->[$index], "$file\[$index\]" );
                }
                next;
            }
            die "config payload must be an object: $file\n";
        }
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

        if ( $kind eq "glab-groups/projects" ) {
            my $projects = $payload->{projects};
            ref($projects) eq "ARRAY" or die "$file.projects must be a list\n";
            for my $index ( 0 .. $#{$projects} ) {
                push @{ $config{projects} },
                  _normalize_project( $projects->[$index], "$file.projects[$index]" );
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

    @{ $config{namespaces} } || @{ $config{projects} }
      or die "config dir must contain at least one namespace root or explicit project\n";
    _config_authoritative_projects_by_target_full_path( \%config );
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

    my $check_description =
      !exists( $source_project->{description_known} ) || $source_project->{description_known};
    my $check_lfs =
         $policy->{force_lfs}
      || !exists( $source_project->{lfs_enabled_known} )
      || $source_project->{lfs_enabled_known};

    if ($check_description) {
        my $source_description = _normalize_description( $source_project->{description} );
        my $target_description = _normalize_description( $target_project->{description} );
        return "update_project" if $target_description ne $source_description;
    }

    if ($check_lfs) {
        my $target_lfs_enabled = !!$target_project->{lfs_enabled};
        my $source_lfs_enabled = !!( $policy->{force_lfs} || $source_project->{lfs_enabled} );
        return "update_project" if $target_lfs_enabled != $source_lfs_enabled;
    }

    if ( exists $target_project->{group_runners_enabled} ) {
        return "update_project" if !!$target_project->{group_runners_enabled};
    }
    if ( exists $target_project->{shared_runners_enabled} ) {
        return "update_project" if !!$target_project->{shared_runners_enabled};
    }

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

    my ( $refs_fh, $refs_path ) = tempfile();
    print {$refs_fh} join( "\n", @rev_args ), "\n";
    close $refs_fh;

    my $pack_cmd = join q{ },
      _shell_quote("git"),
      _shell_quote("-C"),
      _shell_quote($repo_dir),
      _shell_quote("pack-objects"),
      _shell_quote("--stdout"),
      _shell_quote("--quiet"),
      _shell_quote("--revs"),
      "<",
      _shell_quote($refs_path),
      "|",
      _shell_quote("wc"),
      _shell_quote("-c"),
      "2>&1";
    my $pack_result = _run_shell_command(
        $pack_cmd,
        {
            timeout => 300,
        }
    );
    unlink $refs_path;
    $pack_result->{status} == 0 or die "git pack-objects failed: $pack_result->{output}\n";
    my ($packed_bytes) = $pack_result->{output} =~ /(\d+)/;
    defined $packed_bytes or die "unable to parse packed size from git pack-objects output: $pack_result->{output}\n";
    $packed_bytes += 0;

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

    my @oversized_blobs;
    for my $line ( split /\n/, $cat_result->{output} ) {
        next unless $line =~ /\A([0-9a-f]{40})\s+(\w+)\s+(\d+)\z/;
        my ( $object_id, $type, $size ) = ( $1, $2, $3 + 0 );
        if ( $type eq "blob" && $size > $max_blob_bytes ) {
            push @oversized_blobs, { object_id => $object_id, size => $size };
        }
    }
    return {
        total_bytes => $packed_bytes,
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

    $opt{batch_size} > 0 or die "batch-size must be greater than zero\n";
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
        discover_output => "discover.json",
        batch_size => 10,
        max_batches => 0,
        output => "plan.json",
        summary => "plan.md",
    );
    GetOptionsFromArray(
        \@argv,
        "config-dir=s" => \$opt{config_dir},
        "batch-size=i" => \$opt{batch_size},
        "max-batches=i" => \$opt{max_batches},
        "discover-output=s" => \$opt{discover_output},
        "output=s" => \$opt{output},
        "summary=s" => \$opt{summary},
    ) or die _usage();
    $opt{max_batches} >= 0 or die "max-batches must be zero or greater\n";

    my $config = load_config_dir( $opt{config_dir} );
    warn "performing live inventory discovery\n";
    my $normalized = _normalize_inventory( _discover_inventory($config) );
    _write_json( $opt{discover_output}, $normalized ) if $opt{discover_output};
    my $plan = _build_plan(
        $config,
        $normalized,
        $opt{batch_size},
        {
            max_batches => $opt{max_batches},
        },
    );
    $plan->{total_targets} > 0
      or die "discovery produced zero targets; refusing to continue with a no-op mirror plan\n";
    _write_json( $opt{output}, $plan );
    _write_text( $opt{summary}, _render_plan_summary($plan) );
    return 0;
}

sub _build_group_batches {
    my ( $plan, $batch_size ) = @_;
    my @batches;
    my %seen_groups;
    my $current_batch;
    my $current_group = undef;

    for my $index ( 0 .. $#{$plan} ) {
        my $entry = $plan->[$index];
        my $group_path = $entry->{target_namespace_path} || q{};
        my $is_new_group = !defined $current_group || $group_path ne $current_group;

        if ( !$current_batch ) {
            $current_batch = {
                end_index => $index,
                group_paths => [],
                start_index => $index,
                target_count => 0,
            };
        }
        elsif ( $is_new_group && $current_batch->{target_count} >= $batch_size ) {
            push @batches, $current_batch;
            $current_batch = {
                end_index => $index,
                group_paths => [],
                start_index => $index,
                target_count => 0,
            };
        }

        if ($is_new_group) {
            push @{ $current_batch->{group_paths} }, $group_path;
            $seen_groups{$group_path} = 1;
        }

        $current_batch->{end_index} = $index;
        $current_batch->{target_count}++;
        $current_group = $group_path;
    }

    push @batches, $current_batch if $current_batch;
    return ( \@batches, scalar keys %seen_groups );
}

sub _select_effective_batch_size {
    my ( $plan, $batch_size, $max_batches ) = @_;
    $batch_size > 0 or die "batch-size must be greater than zero\n";

    my ( $batches, $total_groups ) = _build_group_batches( $plan, $batch_size );
    return ( $batch_size, $batches, $total_groups )
      if !$max_batches || scalar(@{$batches}) <= $max_batches;

    my $total_targets = scalar @{$plan};
    my $effective_batch_size = $batch_size;
    my $minimum_batch_size =
      int( ( $total_targets + $max_batches - 1 ) / $max_batches );
    $effective_batch_size = $minimum_batch_size
      if $effective_batch_size < $minimum_batch_size;

    while (1) {
        ( $batches, $total_groups ) =
          _build_group_batches( $plan, $effective_batch_size );
        last if scalar(@{$batches}) <= $max_batches;
        last if $effective_batch_size >= $total_targets;

        my $next_batch_size = int(
            ( $effective_batch_size * scalar(@{$batches}) + $max_batches - 1 ) /
              $max_batches
        );
        $next_batch_size = $effective_batch_size + 1
          if $next_batch_size <= $effective_batch_size;
        $next_batch_size = $total_targets
          if $next_batch_size > $total_targets;
        $effective_batch_size = $next_batch_size;
    }

    return ( $effective_batch_size, $batches, $total_groups );
}

sub _cmd_prepare_target {
    my (@argv) = @_;
    my %opt = (
        output => "prepared.json",
        batch_start => 0,
        batch_stride => 1,
        batch_limit => 0,
    );
    GetOptionsFromArray(
        \@argv,
        "plan=s" => \$opt{plan},
        "output=s" => \$opt{output},
        "batch-start=i" => \$opt{batch_start},
        "batch-stride=i" => \$opt{batch_stride},
        "batch-limit=i" => \$opt{batch_limit},
    ) or die _usage();
    $opt{batch_start} >= 0 or die "batch-start must be zero or greater\n";
    $opt{batch_stride} > 0 or die "batch-stride must be greater than zero\n";
    $opt{batch_limit} >= 0 or die "batch-limit must be zero or greater\n";

    my $plan = _read_json( $opt{plan} );
    my $client = _load_target_client();
    my @entries = @{ $plan->{plan} || [] };
    my @batches = @{ $plan->{batches} || [] };
    my @prepared;
    my $processed_batches = 0;
    my $total_batches = scalar @batches;

    if (@batches) {
        for ( my $batch_index = $opt{batch_start}; $batch_index < $total_batches; $batch_index += $opt{batch_stride} ) {
            last if $opt{batch_limit} > 0 && $processed_batches >= $opt{batch_limit};
            my $batch = $batches[$batch_index];
            next unless ref($batch) eq "HASH";
            my $start = $batch->{start_index};
            my $end = $batch->{end_index};
            next unless defined $start && defined $end;
            last if $start > $#entries;
            $end = $#entries if $end > $#entries;

            for my $index ( $start .. $end ) {
                my $entry = $entries[$index];
                next if $entry->{action} eq "skip" || $entry->{action} eq "fail";
                push @prepared, _ensure_target_project( $client, $entry );
            }
            $processed_batches++;
        }
    }
    else {
        for my $entry (@entries) {
            next if $entry->{action} eq "skip" || $entry->{action} eq "fail";
            push @prepared, _ensure_target_project( $client, $entry );
        }
    }
    _write_json(
        $opt{output},
        {
            batch_start => $opt{batch_start},
            batch_stride => $opt{batch_stride},
            batch_limit => $opt{batch_limit},
            processed_batches => $processed_batches,
            total_batches => $total_batches,
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
        batch_size => 10,
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
    my @batches = @{ $plan->{batches} || [] };
    my $total_batches = scalar @batches;

    my @results;
    my $processed_batches = 0;
    open( my $jsonl_fh, ">:encoding(UTF-8)", $opt{jsonl} ) or die "unable to write $opt{jsonl}\n";

    for ( my $batch_index = $opt{batch_start}; $batch_index < $total_batches; $batch_index += $opt{batch_stride} ) {
        last if $opt{batch_limit} > 0 && $processed_batches >= $opt{batch_limit};
        my $batch = $batches[$batch_index];
        next unless ref($batch) eq "HASH";
        my $start = $batch->{start_index};
        my $end = $batch->{end_index};
        next unless defined $start && defined $end;
        last if $start > $#entries;
        $end = $#entries if $end > $#entries;

        for my $index ( $start .. $end ) {
            my $entry = $entries[$index];
            my $result = eval { _mirror_entry( $target_client, $source_auth, $entry ) };
            if ($@) {
                $result = {
                    target_full_path => $entry->{target_full_path},
                    planned_action => $entry->{action},
                    status => "failed",
                    reason => "Repository failed after unrecoverable mirror error.",
                    error => _trim_error($@),
                };
            }
            $result = _sanitize_payload($result);
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
    my $source_auth = _load_source_auth();
    my @inventory;
    my $authoritative_projects = _config_authoritative_projects_by_target_full_path($config);
    my $has_authoritative_projects = scalar keys %{$authoritative_projects};
    my %authoritative_namespaces;
    for my $namespace ( @{ $config->{namespaces} } ) {
        my $policy = _merge_policy( $config->{defaults}, $namespace, {} );
        my $namespace_inventory = _discover_namespace_inventory( $namespace, $policy, $source_auth );
        if ( !$has_authoritative_projects ) {
            push @inventory, @{$namespace_inventory};
            next;
        }
        for my $bucket ( @{$namespace_inventory} ) {
            my @projects;
            for my $source_project ( @{ $bucket->{projects} || [] } ) {
                my $source_full_path = _required_string( $source_project->{path_with_namespace}, "path_with_namespace" );
                my $target_paths = _resolve_namespace_project_target_paths(
                    $bucket->{namespace},
                    $bucket->{group_path},
                    $source_full_path,
                );
                my $authoritative = $authoritative_projects->{ $target_paths->{target_full_path} };
                if ($authoritative) {
                    my $existing = $authoritative_namespaces{ $target_paths->{target_full_path} };
                    if (
                        $existing
                        && (
                            ( $existing->{target_owner_path} || q{} ) ne ( $bucket->{namespace}->{target_owner_path} || q{} )
                            || ( $existing->{target_namespace_path} || q{} ) ne ( $bucket->{namespace}->{target_namespace_path} || q{} )
                            || ( $existing->{source_group_url} || q{} ) ne ( $bucket->{namespace}->{source_group_url} || q{} )
                        )
                      )
                    {
                        die "authoritative projects.yml target maps to multiple namespace entries: $target_paths->{target_full_path}\n";
                    }
                    $authoritative_namespaces{ $target_paths->{target_full_path} } = $bucket->{namespace};
                    next;
                }
                push @projects, $source_project;
            }
            next unless @projects;
            push @inventory, { %{$bucket}, projects => \@projects };
        }
    }
    for my $project ( @{ $config->{projects} || [] } ) {
        my $policy = _merge_policy( $config->{defaults}, $project, {} );
        my $target_paths = _resolve_explicit_project_target_paths($project);
        push @inventory, @{
            _discover_project_inventory(
                $project,
                $policy,
                $source_auth,
                {
                    namespace => $authoritative_namespaces{ $target_paths->{target_full_path} },
                },
            )
        };
    }
    return {
        discovered_at => _timestamp(),
        inventory => \@inventory,
    };
}

sub _discover_namespace_inventory {
    my ( $namespace, $policy, $source_auth ) = @_;
    my $source = _parse_source_url(
        $namespace->{source_group_url},
        sub {
            my ($base_url) = @_;
            return _is_gitlab_instance_root( $base_url, $policy );
        },
    );

    if ( $source->{kind} eq "gitlab_group" ) {
        my $source_client = _make_gitlab_client( $source->{base_url}, undef, undef );
        my $source_group = _get_group( $source_client, $source->{root_path}, _gitlab_read_request_opt($policy) );
        return [] if !$source_group;
        my $projects = _list_group_projects( $source_client, $source->{root_path}, $policy, $source_group );
        return [
            {
                namespace => $namespace,
                group_id => $source_group->{id},
                group_path => $source->{root_path},
                base_url => $source->{base_url},
                projects => $projects,
            },
        ];
    }

    if ( $source->{kind} eq "gitlab_instance_root" ) {
        my $source_client = _make_gitlab_client( $source->{base_url}, undef, undef );
        my @inventory;
        for my $group ( @{ _list_gitlab_top_level_groups( $source_client, $policy ) } ) {
            next unless ref($group) eq "HASH";
            my $group_path = _required_relative_namespace_path(
                $group->{full_path} || $group->{path},
                "gitlab top-level group path",
            );
            my $projects = _list_group_projects( $source_client, $group_path, $policy );
            push @inventory,
              {
                namespace => {
                    %{$namespace},
                    target_namespace_path => _join_path( $namespace->{target_namespace_path}, $group_path ),
                },
                group_id => $group->{id},
                group_path => $group_path,
                base_url => $source->{base_url},
                projects => $projects,
              };
        }
        return \@inventory;
    }

    if ( $source->{kind} eq "github_org" ) {
        my $github_source_auth = _github_installation_source_auth(
            $source_auth,
            $source->{base_url},
            $source->{root_path},
            $policy,
        );
        my $projects = _list_github_org_projects(
            $source->{base_url},
            $source->{root_path},
            $policy,
            $github_source_auth,
        );
        return [
            {
                namespace => $namespace,
                group_path => $source->{root_path},
                base_url => $source->{base_url},
                projects => $projects,
            },
        ];
    }

    if ( $source->{kind} eq "cgit_root" ) {
        my $group_path = _source_root_key( $source->{base_url} );
        my $projects = _list_cgit_root_projects( $source->{base_url}, $group_path, $policy );
        return [
            {
                namespace => $namespace,
                group_path => $group_path,
                base_url => $source->{base_url},
                projects => $projects,
            },
        ];
    }

    if ( $source->{kind} eq "gitiles_root" ) {
        my $group_path = _source_root_key( $source->{base_url} );
        my $projects = _list_root_index_projects(
            $source->{base_url},
            $group_path,
            $policy,
            { allow_nested_paths => 1 },
        );
        return [
            {
                namespace => $namespace,
                group_path => $group_path,
                base_url => $source->{base_url},
                projects => $projects,
            },
        ];
    }

    die "unsupported source kind: $source->{kind}\n";
}

sub _discover_project_inventory {
    my ( $project, $policy, $source_auth, $opt ) = @_;
    $opt ||= {};
    my $source = _parse_source_project_url( $project->{source_project_url}, $project->{name} );
    my $project_source_auth = {};
    my $source_auth_mode = "none";
    if ( $source->{kind} eq "github_project" ) {
        $project_source_auth = _github_installation_source_auth(
            $source_auth,
            $source->{base_url},
            $source->{group_path},
            $policy,
        );
        $source_auth_mode = "github_app";
    }
    my $chosen_clone_url = $source->{clone_url};
    my $available = _discover_project_remote_refs( $source, $project_source_auth, $policy, \$chosen_clone_url );
    my $has_refs =
         scalar( keys %{ $available->{branches} || {} } )
      || scalar( keys %{ $available->{tags} || {} } );
    $chosen_clone_url = _strip_auth_from_url($chosen_clone_url);

    return [
        {
            base_url => $source->{base_url},
            group_path => $source->{group_path},
            namespace => $opt->{namespace},
            project_entry => $project,
            source_auth_mode => $source_auth_mode,
            projects => [
                {
                    archived => JSON::PP::false,
                    available_branches => [ sort keys %{ $available->{branches} || {} } ],
                    available_tags => [ sort keys %{ $available->{tags} || {} } ],
                    default_branch => $available->{default_branch},
                    description => "",
                    description_known => JSON::PP::false,
                    empty_repo => $has_refs ? JSON::PP::false : JSON::PP::true,
                    http_url_to_repo => $chosen_clone_url,
                    lfs_enabled => JSON::PP::false,
                    lfs_enabled_known => JSON::PP::false,
                    path_with_namespace => $source->{path_with_namespace},
                    ssh_url_to_repo => $chosen_clone_url,
                    visibility => "public",
                },
            ],
        },
    ];
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
    my ( $config, $inventory, $batch_size, $opt ) = @_;
    $opt ||= {};
    my @plan;
    my %counts = (
        fail => 0,
        skip => 0,
        sync => 0,
    );

    for my $bucket ( @{ $inventory->{inventory} || [] } ) {
        if ( ref( $bucket->{project_entry} ) eq "HASH" ) {
            my $project_entry = $bucket->{project_entry};
            my $matched_namespace =
              ref( $bucket->{namespace} ) eq "HASH" ? $bucket->{namespace} : undef;

            for my $source_project ( @{ $bucket->{projects} || [] } ) {
                my $source_full_path = _required_string( $source_project->{path_with_namespace}, "path_with_namespace" );
                my $target_paths = _resolve_explicit_project_target_paths(
                    $project_entry,
                    $matched_namespace,
                );
                my $policy =
                  $matched_namespace
                  ? _merge_policy( $config->{defaults}, $matched_namespace, $project_entry )
                  : _merge_policy( $config->{defaults}, $project_entry, {} );
                my $skip_reason = _config_exclusion_reason(
                    $config,
                    $target_paths->{target_relative_project_path},
                    $target_paths->{target_full_path},
                );
                if ( !$skip_reason && $source_project->{archived} ) {
                    $skip_reason = "Archived source repository is excluded from mirroring.";
                }
                if ( !$skip_reason ) {
                    $skip_reason = _gitlab_invalid_target_path_reason(
                        $target_paths->{target_full_path}
                    );
                }
                my $action =
                    $skip_reason ? "skip"
                  : ref($source_project) eq "HASH" ? "sync"
                  : "fail";
                $counts{$action}++;
                push @plan,
                  {
                    action => $action,
                    policy => $policy,
                    skip_reason => $skip_reason,
                    source_archived => !!$source_project->{archived},
                    source_available_branches =>
                      ref( $source_project->{available_branches} ) eq "ARRAY"
                      ? [ @{ $source_project->{available_branches} } ]
                      : undef,
                    source_available_tags =>
                      ref( $source_project->{available_tags} ) eq "ARRAY"
                      ? [ @{ $source_project->{available_tags} } ]
                      : undef,
                    source_default_branch => $source_project->{default_branch},
                    source_description => _normalize_description( $source_project->{description} ),
                    source_description_known => $source_project->{description_known},
                    source_empty_repo => !!$source_project->{empty_repo},
                    source_full_path => $source_full_path,
                    source_group_id => $bucket->{group_id},
                    source_group_path => $bucket->{group_path},
                    source_auth_mode => $bucket->{source_auth_mode} || "",
                    source_http_url => $source_project->{http_url_to_repo},
                    source_lfs_enabled => !!$source_project->{lfs_enabled},
                    source_lfs_enabled_known => $source_project->{lfs_enabled_known},
                    source_last_activity_at => $source_project->{last_activity_at},
                    source_namespace_full_path =>
                      ref( $source_project->{namespace} ) eq "HASH"
                      ? $source_project->{namespace}->{full_path}
                      : undef,
                    source_namespace_id =>
                      ref( $source_project->{namespace} ) eq "HASH"
                      ? $source_project->{namespace}->{id}
                      : undef,
                    source_project_id => $source_project->{id},
                    source_ssh_url => $source_project->{ssh_url_to_repo},
                    source_visibility => $source_project->{visibility},
                    target_full_path => $target_paths->{target_full_path},
                    target_relative_project_path => $target_paths->{target_relative_project_path},
                    target_namespace_path => $target_paths->{target_namespace_path},
                  };
            }
            next;
        }

        my $namespace = $bucket->{namespace};
        my $source_group_path = $bucket->{group_path};
        my $target_root_path = _resolve_target_root_group_path($namespace);

        for my $source_project ( @{ $bucket->{projects} || [] } ) {
            my $source_full_path = _required_string( $source_project->{path_with_namespace}, "path_with_namespace" );
            next if $source_full_path eq $source_group_path;
            my $target_paths = _resolve_namespace_project_target_paths(
                $namespace,
                $source_group_path,
                $source_full_path,
            );
            my $policy = _merge_policy( $config->{defaults}, $namespace, {} );
            my $skip_reason = _config_exclusion_reason(
                $config,
                $target_paths->{target_relative_project_path},
                $target_paths->{target_full_path},
            );
            if ( !$skip_reason && $source_project->{archived} ) {
                $skip_reason = "Archived source repository is excluded from mirroring.";
            }
            if ( !$skip_reason ) {
                $skip_reason = _gitlab_invalid_target_path_reason(
                    $target_paths->{target_full_path}
                );
            }
            my $action =
                $skip_reason ? "skip"
              : ref($source_project) eq "HASH" ? "sync"
              : "fail";
            $counts{$action}++;
            push @plan,
              {
                action => $action,
                policy => $policy,
                skip_reason => $skip_reason,
                source_archived => !!$source_project->{archived},
                source_available_branches =>
                  ref( $source_project->{available_branches} ) eq "ARRAY"
                  ? [ @{ $source_project->{available_branches} } ]
                  : undef,
                source_available_tags =>
                  ref( $source_project->{available_tags} ) eq "ARRAY"
                  ? [ @{ $source_project->{available_tags} } ]
                  : undef,
                source_default_branch => $source_project->{default_branch},
                source_description => _normalize_description( $source_project->{description} ),
                source_description_known => $source_project->{description_known},
                source_empty_repo => !!$source_project->{empty_repo},
                source_full_path => $source_full_path,
                source_group_id => $bucket->{group_id},
                source_group_path => $source_group_path,
                source_http_url => $source_project->{http_url_to_repo},
                source_lfs_enabled => !!$source_project->{lfs_enabled},
                source_lfs_enabled_known => $source_project->{lfs_enabled_known},
                source_last_activity_at => $source_project->{last_activity_at},
                source_namespace_full_path =>
                  ref( $source_project->{namespace} ) eq "HASH"
                  ? $source_project->{namespace}->{full_path}
                  : undef,
                source_namespace_id =>
                  ref( $source_project->{namespace} ) eq "HASH"
                  ? $source_project->{namespace}->{id}
                  : undef,
                source_project_id => $source_project->{id},
                source_ssh_url => $source_project->{ssh_url_to_repo},
                source_visibility => $source_project->{visibility},
                target_full_path => $target_paths->{target_full_path},
                target_relative_project_path => $target_paths->{target_relative_project_path},
                target_namespace_path => $target_paths->{target_namespace_path},
              };
        }
    }

    @plan = sort {
        ( $a->{target_namespace_path} || q{} ) cmp ( $b->{target_namespace_path} || q{} )
          || $a->{target_full_path} cmp $b->{target_full_path}
    } @plan;
    my ( $effective_batch_size, $batches, $total_groups ) =
      _select_effective_batch_size( \@plan, $batch_size, $opt->{max_batches} || 0 );
    return {
        batches => $batches,
        batch_size => $effective_batch_size,
        counts => \%counts,
        generated_at => _timestamp(),
        max_batches => $opt->{max_batches} || 0,
        plan => \@plan,
        total_batches => scalar @{$batches},
        total_groups => $total_groups,
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
            status => "skipped",
            reason => "Repository skipped after plan error.",
            error => "Plan marked target as failed",
        };
    }

    my $prepared = _ensure_target_project( $target_client, $entry );
    my $prepared_action =
        $prepared->{created} ? "create_project"
      : $prepared->{updated} ? "update_project"
      : "mirror_only";
    if ( $entry->{source_empty_repo} ) {
        _finalize_target_project( $target_client, $prepared->{project_id}, $entry->{source_default_branch} || "", $entry );
        my $verified = _verify_entry( $target_client, $entry );
        return {
            target_full_path => $entry->{target_full_path},
            planned_action => $entry->{action},
            prepared_action => $prepared_action,
            status => $prepared->{created} ? "created_empty" : "updated_empty",
            prepared => $prepared,
            verify => $verified,
        };
    }

    my $workdir = tempdir( CLEANUP => 1 );
    my $repo_dir = File::Spec->catdir( $workdir, "repo" );
    my $init_result = _run_command( [ "git", "init", $repo_dir ], { timeout => 120 } );
    $init_result->{status} == 0 or die "git init failed: $init_result->{output}\n";

    my $entry_source_auth = _resolve_source_auth_for_entry( $source_auth, $entry );
    my $source_url = _maybe_auth_url( $entry->{source_http_url}, $entry_source_auth->{username}, $entry_source_auth->{token} );
    my $chosen_source_url = $source_url;
    my $available;
    if (
        ref( $entry->{source_available_branches} ) eq "ARRAY"
        || ref( $entry->{source_available_tags} ) eq "ARRAY"
      )
    {
        my %branches = map { $_ => 1 } @{ $entry->{source_available_branches} || [] };
        my %tags = map { $_ => 1 } @{ $entry->{source_available_tags} || [] };
        $available = {
            branches => \%branches,
            default_branch => $entry->{source_default_branch} || "",
            tags => \%tags,
        };
    }
    else {
        $available = _discover_remote_refs_from_urls(
            [ $source_url, _fallback_clone_url($source_url) ],
            $entry->{policy},
            \$chosen_source_url,
        );
    }
    my $target_url = _maybe_auth_url( _project_git_url( $target_client->{base_url}, $entry->{target_full_path} ), $target_client->{username}, $target_client->{token} );

    my $remote_result = _run_command( [ "git", "-C", $repo_dir, "remote", "add", "source", $chosen_source_url ], { timeout => 60 } );
    $remote_result->{status} == 0 or die "git remote add source failed: $remote_result->{output}\n";
    $remote_result = _run_command( [ "git", "-C", $repo_dir, "remote", "add", "target", $target_url ], { timeout => 60 } );
    $remote_result->{status} == 0 or die "git remote add target failed: $remote_result->{output}\n";

    my $default_branch = $entry->{source_default_branch} || $available->{default_branch} || "";
    my $selected = resolve_selected_refs( $default_branch, $entry->{policy}, $available );
    @{ $selected->{branches} } or die "no source branches resolved for $entry->{source_full_path}\n";

    _fetch_selected_refs( $repo_dir, $selected, $entry->{policy} );
    my $checkout_result = _run_command( [ "git", "-C", $repo_dir, "checkout", "-f", $selected->{branches}->[0] ], { timeout => 300 } );
    $checkout_result->{status} == 0 or die "git checkout failed for branch $selected->{branches}->[0]: $checkout_result->{output}\n";

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
        _ensure_target_lfs_enabled( $target_client, $prepared->{project_id} );
        _prepare_lfs( $repo_dir, $entry->{policy} );
        for my $branch ( @{ $selected->{branches} || [] } ) {
            my $lfs_result = _run_command(
                [ "git", "-C", $repo_dir, "lfs", "fetch", "source", "refs/heads/$branch" ],
                _git_command_options( $entry->{policy}, JSON::PP::true )
            );
            $lfs_result->{status} == 0 or die "git lfs fetch failed for branch $branch: $lfs_result->{output}\n";
        }
        for my $tag ( @{ $selected->{tags} || [] } ) {
            my $lfs_result = _run_command(
                [ "git", "-C", $repo_dir, "lfs", "fetch", "source", "refs/tags/$tag" ],
                _git_command_options( $entry->{policy}, JSON::PP::true )
            );
            $lfs_result->{status} == 0 or die "git lfs fetch failed for tag $tag: $lfs_result->{output}\n";
        }
        my $lfs_result = _run_command(
            [ "git", "-C", $repo_dir, "lfs", "push", "--all", "target" ],
            _git_command_options( $entry->{policy}, JSON::PP::true )
        );
        $lfs_result->{status} == 0 or die "git lfs push failed: $lfs_result->{output}\n";
    }

    _push_selected_refs( $repo_dir, $selected, $entry->{policy}, $default_branch );
    _finalize_target_project( $target_client, $prepared->{project_id}, $default_branch, $entry );
    my $verified = _verify_entry( $target_client, $entry, $selected, $default_branch );

    return {
        target_full_path => $entry->{target_full_path},
        planned_action => $entry->{action},
        prepared_action => $prepared_action,
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
    my ( $target_client, $entry, $selected, $source_default_branch ) = @_;
    my $project = _get_project( $target_client, $entry->{target_full_path} );
    return {
        target_full_path => $entry->{target_full_path},
        exists => $project ? JSON::PP::true : JSON::PP::false,
    } unless $project;

    my %branches;
    my %tags;
    if ($selected) {
        for my $branch ( @{ $selected->{branches} || [] } ) {
            my $target_branch_name =
              ( $source_default_branch && $branch eq $source_default_branch )
              ? $TARGET_SYNC_BRANCH
              : $branch;
            $branches{$target_branch_name} = _get_branch( $target_client, $project->{id}, $target_branch_name ) ? JSON::PP::true : JSON::PP::false;
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
        "- total target groups: $plan->{total_groups}\n",
        "- batch size: $plan->{batch_size}\n",
        "- total batches: $plan->{total_batches}\n",
        "- sync: $plan->{counts}->{sync}\n",
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
    _reject_visibility_key( $payload, "$label.defaults" );
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.defaults.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.defaults.additional_tags" ),
        allow_blob_rewrite => _bool_or_default( $payload->{allow_blob_rewrite}, 1 ),
        batch_size => _defaulted_positive_int( $payload->{batch_size}, $DEFAULTS{batch_size}, "$label.defaults.batch_size" ),
        force_lfs => _bool_or_default( $payload->{force_lfs}, 0 ),
        git_timeout_seconds => _defaulted_positive_int( $payload->{git_timeout_seconds}, $DEFAULTS{git_timeout_seconds}, "$label.defaults.git_timeout_seconds" ),
        max_blob_bytes => _defaulted_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.defaults.max_blob_bytes" ),
        max_parallel => _defaulted_positive_int( $payload->{max_parallel}, $DEFAULTS{max_parallel}, "$label.defaults.max_parallel" ),
        mirror_pristine_tar => _bool_or_default( $payload->{mirror_pristine_tar}, 1 ),
        gitlab_source_include_subgroups => _bool_or_default( $payload->{gitlab_source_include_subgroups}, 0 ),
        read_retry_attempts => _defaulted_positive_int( $payload->{read_retry_attempts}, $GITLAB_READ_DEFAULTS{retry_attempts}, "$label.defaults.read_retry_attempts" ),
        read_retry_backoff_seconds => _defaulted_positive_int( $payload->{read_retry_backoff_seconds}, $GITLAB_READ_DEFAULTS{retry_backoff_seconds}, "$label.defaults.read_retry_backoff_seconds" ),
        retry_attempts => _defaulted_positive_int( $payload->{retry_attempts}, $DEFAULTS{retry_attempts}, "$label.defaults.retry_attempts" ),
        retry_backoff_seconds => _defaulted_positive_int( $payload->{retry_backoff_seconds}, $DEFAULTS{retry_backoff_seconds}, "$label.defaults.retry_backoff_seconds" ),
        size_limit_bytes => _defaulted_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.defaults.size_limit_bytes" ),
        target_branches_protect => _normalize_ref_specs( $payload->{target_branches_protect}, "$label.defaults.target_branches_protect" ),
    };
}

sub _normalize_namespace {
    my ( $payload, $label ) = @_;
    ref($payload) eq "HASH" or die "$label must be an object\n";
    _reject_visibility_key( $payload, $label );
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.additional_tags" ),
        allow_blob_rewrite => _optional_bool( $payload->{allow_blob_rewrite} ),
        force_lfs => _optional_bool( $payload->{force_lfs} ),
        git_timeout_seconds => $payload->{git_timeout_seconds},
        gitlab_source_include_subgroups => _optional_bool( $payload->{gitlab_source_include_subgroups} ),
        mirror_pristine_tar => _optional_bool( $payload->{mirror_pristine_tar} ),
        name => _required_string( $payload->{name}, "$label.name" ),
        read_retry_attempts => _optional_positive_int( $payload->{read_retry_attempts}, "$label.read_retry_attempts" ),
        read_retry_backoff_seconds => _optional_positive_int( $payload->{read_retry_backoff_seconds}, "$label.read_retry_backoff_seconds" ),
        retry_attempts => _optional_positive_int( $payload->{retry_attempts}, "$label.retry_attempts" ),
        retry_backoff_seconds => _optional_positive_int( $payload->{retry_backoff_seconds}, "$label.retry_backoff_seconds" ),
        size_limit_bytes => _optional_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.size_limit_bytes" ),
        max_blob_bytes => _optional_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.max_blob_bytes" ),
        source_group_url => _required_https_url( $payload->{source_group_url}, "$label.source_group_url" ),
        target_branches_protect => _normalize_ref_specs( $payload->{target_branches_protect}, "$label.target_branches_protect" ),
        target_owner_path => _required_relative_namespace_path( $payload->{target_owner_path}, "$label.target_owner_path" ),
        target_namespace_path => _required_relative_namespace_path( $payload->{target_namespace_path}, "$label.target_namespace_path" ),
    };
}

sub _normalize_project {
    my ( $payload, $label ) = @_;
    ref($payload) eq "HASH" or die "$label must be an object\n";
    _reject_visibility_key( $payload, $label );
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.additional_tags" ),
        allow_blob_rewrite => _optional_bool( $payload->{allow_blob_rewrite} ),
        force_lfs => _optional_bool( $payload->{force_lfs} ),
        git_timeout_seconds => $payload->{git_timeout_seconds},
        gitlab_source_include_subgroups => _optional_bool( $payload->{gitlab_source_include_subgroups} ),
        mirror_pristine_tar => _optional_bool( $payload->{mirror_pristine_tar} ),
        name => _required_path_segment( $payload->{name}, "$label.name" ),
        read_retry_attempts => _optional_positive_int( $payload->{read_retry_attempts}, "$label.read_retry_attempts" ),
        read_retry_backoff_seconds => _optional_positive_int( $payload->{read_retry_backoff_seconds}, "$label.read_retry_backoff_seconds" ),
        retry_attempts => _optional_positive_int( $payload->{retry_attempts}, "$label.retry_attempts" ),
        retry_backoff_seconds => _optional_positive_int( $payload->{retry_backoff_seconds}, "$label.retry_backoff_seconds" ),
        size_limit_bytes => _optional_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.size_limit_bytes" ),
        max_blob_bytes => _optional_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.max_blob_bytes" ),
        source_project_url => _required_https_url( $payload->{source_project_url}, "$label.source_project_url" ),
        target_branches_protect => _normalize_ref_specs( $payload->{target_branches_protect}, "$label.target_branches_protect" ),
        target_group_path => _required_relative_namespace_path( $payload->{target_group_path}, "$label.target_group_path" ),
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
          gitlab_source_include_subgroups
          max_blob_bytes
          mirror_pristine_tar
          read_retry_attempts
          read_retry_backoff_seconds
          retry_attempts
          retry_backoff_seconds
          size_limit_bytes
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
    $policy->{target_branches_protect} = [
        @{ $defaults->{target_branches_protect} || [] },
        @{ $namespace->{target_branches_protect} || [] },
        @{ $override->{target_branches_protect} || [] },
    ];
    $policy->{git_timeout_seconds} ||= $DEFAULTS{git_timeout_seconds};
    $policy->{read_retry_attempts} ||= $GITLAB_READ_DEFAULTS{retry_attempts};
    $policy->{read_retry_backoff_seconds} ||= $GITLAB_READ_DEFAULTS{retry_backoff_seconds};
    $policy->{retry_attempts} ||= $DEFAULTS{retry_attempts};
    $policy->{retry_backoff_seconds} ||= $DEFAULTS{retry_backoff_seconds};
    $policy->{size_limit_bytes} ||= $DEFAULTS{size_limit_bytes};
    $policy->{max_blob_bytes} ||= $DEFAULTS{max_blob_bytes};
    return $policy;
}

sub _load_target_client {
    my $token_secret_name = _required_secret_name( $ENV{GL_TARGET_TOKEN_SECRET_NAME}, "GL_TARGET_TOKEN_SECRET_NAME" );
    return _make_gitlab_client(
        _required_https_url( _required_env_file("GL_BASE_URL"), "GL_BASE_URL" ),
        "oauth2",
        _required_env_file($token_secret_name),
    );
}

sub _resolve_target_root_group_path {
    my ($namespace) = @_;
    return _required_relative_namespace_path(
        $namespace->{target_owner_path},
        "target_owner_path",
    );
}

sub _load_source_auth {
    my $username = _optional_env_file("GL_GROUPS_SOURCE_USERNAME");
    my $token = _optional_env_file("GL_GROUPS_SOURCE_TOKEN");
    my $github_app_id = _optional_env_file("GH_ORG_READ_APP_ID");
    my $github_app_install_id = _optional_env_file("GH_ORG_READ_APP_INSTALL_ID");
    my $github_app_pem = _optional_env_file("GH_ORG_READ_APP_PEM");
    if ( defined $github_app_id xor defined $github_app_pem ) {
        die "GH_ORG_READ_APP_ID_FILE and GH_ORG_READ_APP_PEM_FILE must be set together\n";
    }
    my $github_app;
    if ( defined $github_app_id && defined $github_app_pem ) {
        $github_app = {
            app_id => _required_numeric_string( $github_app_id, "GH_ORG_READ_APP_ID" ),
            install_id => defined $github_app_install_id
              ? _required_numeric_string( $github_app_install_id, "GH_ORG_READ_APP_INSTALL_ID" )
              : undef,
            pem => _normalize_private_key_secret( $github_app_pem, "GH_ORG_READ_APP_PEM" ),
        };
    }
    return {
        github_app => $github_app,
        github_installation_tokens => {},
        token => $token,
        username => $username,
    };
}

sub _discover_project_remote_refs {
    my ( $source, $project_source_auth, $policy, $chosen_clone_url_ref ) = @_;
    my @candidate_urls = (
        _maybe_auth_url(
            $source->{clone_url},
            $project_source_auth->{username},
            $project_source_auth->{token},
        ),
        _maybe_auth_url(
            $source->{fallback_clone_url},
            $project_source_auth->{username},
            $project_source_auth->{token},
        ),
    );
    return _discover_remote_refs_from_urls( \@candidate_urls, $policy, $chosen_clone_url_ref );
}

sub _make_gitlab_client {
    my ( $base_url, $username, $token ) = @_;
    return {
        base_url => $base_url,
        token => $token,
        username => $username,
    };
}

sub _managed_group_settings_payload {
    return (
        project_creation_level => $GROUP_PROJECT_CREATION_LEVEL,
        shared_runners_setting => $GROUP_SHARED_RUNNERS_SETTING,
        subgroup_creation_level => $GROUP_SUBGROUP_CREATION_LEVEL,
    );
}

sub _ensure_group_path {
    my ( $client, $group_path, $cache ) = @_;
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
        my $created_group = 0;
        if ( !$group ) {
            my %payload = (
                name => $part,
                path => $part,
                _managed_group_settings_payload(),
            );
            $payload{parent_id} = $parent_id if defined $parent_id;
            my $create_ok = eval {
                $group = _gitlab_request( $client, "POST", "/groups", \%payload );
                1;
            };
            $created_group = 1 if $create_ok;
            if ( !$create_ok ) {
                my $create_error = $@ || "unknown group creation error\n";
                if ( _is_gitlab_forbidden_error($create_error) ) {
                    die sprintf(
                        "unable to create required target group %s: target token lacks permission to create this namespace or subgroup; pre-create it or grant group creation rights: %s",
                        $current,
                        $create_error,
                    );
                }
                if ( _is_gitlab_path_conflict_error($create_error) ) {
                    $group = _get_group( $client, $current )
                      || _find_group_by_parent_and_path( $client, $parent_id, $current, $part );
                    die "gitlab group path conflict for $current: $create_error" unless $group;
                }
                die $create_error unless $group;
            }
        }
        $parent_id = $group->{id};
        $cache->{$current} = $parent_id;
    }
    return $cache->{$group_path};
}

sub _find_group_by_parent_and_path {
    my ( $client, $parent_id, $group_path, $path_segment ) = @_;
    my $expected_path = lc($path_segment);
    my $expected_full_path = lc($group_path);
    my @path_builders;
    my $search = uri_escape_utf8($path_segment);

    if ( defined $parent_id ) {
        @path_builders = (
            sub {
                my ($page) = @_;
                return sprintf(
                    "/groups/%d/subgroups?per_page=100&page=%d&search=%s",
                    $parent_id,
                    $page,
                    $search,
                );
            },
            sub {
                my ($page) = @_;
                return sprintf(
                    "/groups/%d/subgroups?per_page=100&page=%d&all_available=true",
                    $parent_id,
                    $page,
                );
            },
        );
    }
    else {
        @path_builders = (
            sub {
                my ($page) = @_;
                return sprintf(
                    "/groups?top_level_only=true&per_page=100&page=%d&search=%s",
                    $page,
                    $search,
                );
            },
            sub {
                my ($page) = @_;
                return sprintf(
                    "/groups?top_level_only=true&per_page=100&page=%d&all_available=true",
                    $page,
                );
            },
        );
    }

    for my $path_builder (@path_builders) {
        my $page = 1;
        while (1) {
            my $path = $path_builder->($page);
            my $groups = _gitlab_request( $client, "GET", $path, undef );
            ref($groups) eq "ARRAY" or die "group search response must be a list\n";
            last unless @{$groups};

            for my $group ( @{$groups} ) {
                next unless ref($group) eq "HASH";
                my $candidate_full_path = lc( $group->{full_path} || q{} );
                return $group if $candidate_full_path eq $expected_full_path;
            }
            for my $group ( @{$groups} ) {
                next unless ref($group) eq "HASH";
                my $candidate_path = lc( $group->{path} || q{} );
                return $group if $candidate_path eq $expected_path;
            }

            last if @{$groups} < 100;
            $page++;
        }
    }

    return undef;
}

sub _find_project_by_namespace_and_path {
    my ( $client, $group_id, $project_path, $path_segment ) = @_;
    defined $group_id or return undef;
    my $expected_path = lc( _required_string( $path_segment, "project path segment" ) );
    my $expected_full_path = lc( _required_string( $project_path, "target_full_path" ) );
    my $search = uri_escape_utf8($path_segment);
    my @path_builders = (
        sub {
            my ($page) = @_;
            return sprintf(
                "/groups/%d/projects?include_subgroups=false&with_shared=false&per_page=100&page=%d&search=%s&simple=true",
                $group_id,
                $page,
                $search,
            );
        },
        sub {
            my ($page) = @_;
            return sprintf(
                "/groups/%d/projects?include_subgroups=false&with_shared=false&per_page=100&page=%d&simple=true",
                $group_id,
                $page,
            );
        },
    );

    for my $path_builder (@path_builders) {
        my $page = 1;
        while (1) {
            my $path = $path_builder->($page);
            my $projects = _gitlab_request( $client, "GET", $path, undef );
            ref($projects) eq "ARRAY" or die "project search response must be a list\n";
            last unless @{$projects};

            for my $project ( @{$projects} ) {
                next unless ref($project) eq "HASH";
                my $candidate_full_path = lc( $project->{path_with_namespace} || q{} );
                return $project if $candidate_full_path eq $expected_full_path;
            }
            for my $project ( @{$projects} ) {
                next unless ref($project) eq "HASH";
                my $candidate_path = lc( $project->{path} || q{} );
                return $project if $candidate_path eq $expected_path;
            }

            last if @{$projects} < 100;
            $page++;
        }
    }

    return undef;
}

sub _is_gitlab_path_conflict_error {
    my ($error) = @_;
    return 0 unless defined $error && !ref($error);
    return 1 if $error =~ /path has already been taken/i;
    return 1 if $error =~ /(?:[:{,\s]|")path(?:["\s]*=>|"\s*:)\s*\[[^\]]*has already been taken[^\]]*\]/i;
    return 0;
}

sub _is_gitlab_already_exists_error {
    my ($error) = @_;
    return 0 unless defined $error && !ref($error);
    return 1 if $error =~ /already exists/i;
    return 1 if $error =~ /has already been taken/i;
    return 0;
}

sub _is_gitlab_missing_ref_error {
    my ($error) = @_;
    return 0 unless defined $error && !ref($error);
    return 1 if $error =~ /invalid reference name/i;
    return 1 if $error =~ /branch .* does not exist/i;
    return 1 if $error =~ /ref .* does not exist/i;
    return 1 if $error =~ /not a valid reference/i;
    return 0;
}

sub _is_gitlab_invalid_namespace_error {
    my ($error) = @_;
    return 0 unless defined $error && !ref($error);
    return 1 if $error =~ /namespace[^[]*\[[^\]]*is not valid[^\]]*\]/i;
    return 1 if $error =~ /namespace_id[^[]*\[[^\]]*is invalid[^\]]*\]/i;
    return 1 if $error =~ /namespace[^[]*\[[^\]]*not found[^\]]*\]/i;
    return 1 if $error =~ /namespace_id[^[]*\[[^\]]*does not exist[^\]]*\]/i;
    return 1 if $error =~ /namespace[^[]*\[[^\]]*can't be blank[^\]]*\]/i;
    return 0;
}

sub _is_gitlab_forbidden_error {
    my ($error) = @_;
    return 0 unless defined $error && !ref($error);
    return 1 if $error =~ /gitlab request failed \[403\]/i;
    return 1 if $error =~ /\b403 Forbidden\b/i;
    return 0;
}

sub _clear_group_path_cache_tree {
    my ( $cache, $group_path ) = @_;
    return if ref($cache) ne "HASH";
    my @parts = split m{/}, $group_path;
    my $current = q{};
    for my $part (@parts) {
        $current = length $current ? "$current/$part" : $part;
        delete $cache->{$current};
    }
}

sub _ensure_target_project {
    my ( $client, $entry ) = @_;
    my $group_cache = $client->{group_path_cache} ||= {};
    my $name = basename( $entry->{target_full_path} );
    my $lookup_existing_project = sub {
        my ($group_id) = @_;
        my $project;
        $project = _get_project( $client, $entry->{target_full_path} )
          if defined $entry->{target_full_path};
        if ( !$project && defined $group_id && defined $entry->{target_full_path} ) {
            $project = _find_project_by_namespace_and_path(
                $client,
                $group_id,
                $entry->{target_full_path},
                $name,
            );
        }
        return $project;
    };
    my $existing =
      defined $entry->{target_project_id}
      ? {
            description => $entry->{target_description},
            group_runners_enabled =>
              defined $entry->{target_group_runners_enabled}
              ? ( $entry->{target_group_runners_enabled} ? JSON::PP::true : JSON::PP::false )
              : undef,
            id => $entry->{target_project_id},
            lfs_enabled => $entry->{target_lfs_enabled} ? JSON::PP::true : JSON::PP::false,
	            shared_runners_enabled =>
	              defined $entry->{target_shared_runners_enabled}
	              ? ( $entry->{target_shared_runners_enabled} ? JSON::PP::true : JSON::PP::false )
		              : undef,
		        }
		      : undef;
    if ( !$existing && defined $entry->{target_full_path} ) {
        $existing = $lookup_existing_project->(undef);
    }
    my $target_group_id;
    if ( !$existing && defined $entry->{target_namespace_path} ) {
        $target_group_id = _ensure_group_path(
            $client,
            $entry->{target_namespace_path},
            $group_cache,
        );
        $existing = $lookup_existing_project->($target_group_id) if !$existing;
    }
    my %payload;
    if ( !exists( $entry->{source_description_known} ) || $entry->{source_description_known} ) {
        $payload{description} = $entry->{source_description};
    }
    if (
        $entry->{policy}->{force_lfs}
        || !exists( $entry->{source_lfs_enabled_known} )
        || $entry->{source_lfs_enabled_known}
      )
    {
        $payload{lfs_enabled} =
          $entry->{policy}->{force_lfs} || $entry->{source_lfs_enabled}
          ? JSON::PP::true
          : JSON::PP::false;
    }
    $payload{group_runners_enabled} = JSON::PP::false;
    $payload{shared_runners_enabled} = JSON::PP::false;

    my $project = $existing;
    my $created = JSON::PP::false;
    my $updated = JSON::PP::false;
    if ( !$project ) {
        my $create_project = sub {
            return _gitlab_request(
                $client,
                "POST",
                "/projects",
                {
                    %payload,
                    name => $name,
                    namespace_id => $target_group_id,
                    path => $name,
                }
            );
        };
        my $create_ok = eval {
            $project = $create_project->();
            1;
        };
        if ($create_ok) {
            $created = JSON::PP::true;
        }
        else {
            my $create_error = $@ || "unknown project creation error\n";
            $project = $lookup_existing_project->($target_group_id);
            if ($project) {
                $created = JSON::PP::false;
            }
            else {
                my $invalid_namespace_error = _is_gitlab_invalid_namespace_error($create_error);
                my $path_conflict_error = _is_gitlab_path_conflict_error($create_error);
                my $refreshed_namespace = 0;
                if ( ( $invalid_namespace_error || $path_conflict_error ) && defined $entry->{target_namespace_path} ) {
                    _clear_group_path_cache_tree( $group_cache, $entry->{target_namespace_path} );
                    $target_group_id = _ensure_group_path(
                        $client,
                        $entry->{target_namespace_path},
                        $group_cache,
                    );
                    $refreshed_namespace = 1;
                }
                if ($path_conflict_error && $refreshed_namespace) {
                    $project = $lookup_existing_project->($target_group_id);
                }
                if ($project) {
                    $created = JSON::PP::false;
                }
                elsif ($invalid_namespace_error) {
                    my $retry_ok = eval {
                        $project = $create_project->();
                        1;
                    };
                    if ($retry_ok) {
                        $created = JSON::PP::true;
                    }
                    else {
                        $create_error = $@ || "unknown project creation error\n";
                        $project = $lookup_existing_project->($target_group_id);
                    }
                }
                elsif ($path_conflict_error) {
                    my $retry_ok = eval {
                        $project = $create_project->();
                        1;
                    };
                    if ($retry_ok) {
                        $created = JSON::PP::true;
                    }
                    else {
                        $create_error = $@ || "unknown project creation error\n";
                        $project = $lookup_existing_project->($target_group_id);
                    }
                }
                if ( !$created && !$project && $path_conflict_error ) {
                    die "gitlab project path conflict for $entry->{target_full_path}: $create_error";
                }
                elsif ( !$created && !$project ) {
                    die $create_error;
                }
            }
        }
    }
    if ( $project && !$created ) {
        my $needs_update = 0;
        if ( exists $payload{description} ) {
            $needs_update = 1
              if _normalize_description( $project->{description} ) ne $payload{description};
        }
        if ( exists $payload{lfs_enabled} ) {
            $needs_update = 1
              if !!$project->{lfs_enabled} != !!$payload{lfs_enabled};
        }
        if ( exists $project->{group_runners_enabled} ) {
            $needs_update = 1
              if !!$project->{group_runners_enabled} != !!$payload{group_runners_enabled};
        }
        if ( exists $project->{shared_runners_enabled} ) {
            $needs_update = 1
              if !!$project->{shared_runners_enabled} != !!$payload{shared_runners_enabled};
        }
        if ($needs_update) {
            $project = _gitlab_request( $client, "PUT", "/projects/" . $project->{id}, \%payload );
            $updated = JSON::PP::true;
        }
    }

    return {
        created => $created,
        project_id => $project->{id},
        updated => $updated,
    };
}

sub _finalize_target_project {
    my ( $client, $project_id, $default_branch, $entry ) = @_;
    my $managed_default_branch = _ensure_managed_target_branches( $client, $project_id, $default_branch, $entry->{policy} );
    my %payload;
    if ( !exists( $entry->{source_description_known} ) || $entry->{source_description_known} ) {
        $payload{description} = $entry->{source_description};
    }
    if ($managed_default_branch) {
        $payload{default_branch} = $managed_default_branch;
    }
    _gitlab_request( $client, "PUT", "/projects/$project_id", \%payload );
}

sub _ensure_target_lfs_enabled {
    my ( $client, $project_id ) = @_;
    _gitlab_request(
        $client,
        "PUT",
        "/projects/$project_id",
        {
            lfs_enabled => JSON::PP::true,
        }
    );
}

sub _get_group {
    my ( $client, $group_path, $opt ) = @_;
    my %request_opt = ( allow_missing => 1, %{ $opt || {} } );
    return _gitlab_request( $client, "GET", "/groups/" . _encode_path($group_path), undef, \%request_opt );
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

sub _get_protected_branch {
    my ( $client, $project_id, $branch_name ) = @_;
    return _gitlab_request(
        $client,
        "GET",
        "/projects/$project_id/protected_branches/" . _encode_path($branch_name),
        undef,
        { allow_missing => 1 }
    );
}

sub _ensure_managed_target_branches {
    my ( $client, $project_id, $source_default_branch, $policy ) = @_;
    return q{} unless $source_default_branch;

    my @specs = (
        {
            name => $TARGET_SYNC_BRANCH,
            ref => $source_default_branch,
        },
        {
            default => JSON::PP::true,
            name => $TARGET_DEFAULT_BRANCH,
            ref => $TARGET_SYNC_BRANCH,
        },
        {
            name => "mcr/feature/init",
            ref => $TARGET_DEFAULT_BRANCH,
        },
        {
            name => "mcr/staging",
            ref => $TARGET_DEFAULT_BRANCH,
        },
        {
            name => "mcr/release",
            ref => $TARGET_DEFAULT_BRANCH,
        },
    );

    my $managed_default_branch = q{};
    my %branch_exists;
    my %managed_branch_names = map { $_->{name} => 1 } @specs;
    for my $spec (@specs) {
        my $exists = _ensure_target_branch_from_ref(
            $client,
            $project_id,
            $spec->{name},
            $spec->{ref},
            \%branch_exists,
        );
        next unless $exists;
        $branch_exists{ $spec->{name} } = 1;
        $managed_default_branch = $spec->{name} if $spec->{default} && $branch_exists{ $spec->{name} };
    }

    my $configured_target_branches_to_protect = _configured_target_branches_to_protect($policy);
    my %configured_target_branch_names = map { $_ => 1 } @{$configured_target_branches_to_protect};
    for my $branch_name ( @{ _list_target_protected_branch_names( $client, $project_id ) } ) {
        next unless $managed_branch_names{$branch_name};
        next if $configured_target_branch_names{$branch_name};
        _ensure_target_branch_unprotected( $client, $project_id, $branch_name );
    }

    for my $branch_name ( @{$configured_target_branches_to_protect} ) {
        next unless $branch_exists{$branch_name};
        _ensure_target_branch_protected( $client, $project_id, $branch_name );
    }

    return $managed_default_branch && $branch_exists{$managed_default_branch}
      ? $managed_default_branch
      : q{};
}

sub _configured_target_branches_to_protect {
    my ($policy) = @_;
    return [] unless ref($policy) eq "HASH";
    my @names;
    my %seen;
    for my $spec ( @{ $policy->{target_branches_protect} || [] } ) {
        next unless ref($spec) eq "HASH";
        my $name = _required_string( $spec->{name}, "target_branches_protect.name" );
        next if $seen{$name}++;
        push @names, $name;
    }
    return \@names;
}

sub _list_target_protected_branch_names {
    my ( $client, $project_id ) = @_;
    my $protected = _gitlab_request( $client, "GET", "/projects/$project_id/protected_branches" );
    ref($protected) eq "ARRAY" or die "protected branches response must be a list\n";
    my @names;
    for my $item ( @{$protected} ) {
        next unless ref($item) eq "HASH";
        next unless defined $item->{name} && length $item->{name};
        push @names, $item->{name};
    }
    return \@names;
}

sub _ensure_target_branch_from_ref {
    my ( $client, $project_id, $branch_name, $ref_name, $branch_exists ) = @_;
    return 1 if $branch_exists && $branch_exists->{$branch_name};

    my $create_ok = eval {
        _gitlab_request(
            $client,
            "POST",
            "/projects/$project_id/repository/branches",
            {
                branch => $branch_name,
                ref => $ref_name,
            }
        );
        1;
    };
    if ($create_ok) {
        $branch_exists->{$branch_name} = 1 if $branch_exists;
        return 1;
    }

    my $create_error = $@ || "unknown branch creation error\n";
    if ( _is_gitlab_already_exists_error($create_error) ) {
        $branch_exists->{$branch_name} = 1 if $branch_exists;
        return 1;
    }
    return 0 if _is_gitlab_missing_ref_error($create_error);
    die $create_error;
}

sub _ensure_target_branch_protected {
    my ( $client, $project_id, $branch_name ) = @_;
    return 1 if _get_protected_branch( $client, $project_id, $branch_name );

    my $protect_ok = eval {
        _gitlab_request(
            $client,
            "POST",
            "/projects/$project_id/protected_branches",
            {
                name => $branch_name,
            }
        );
        1;
    };
    return 1 if $protect_ok;

    my $protect_error = $@ || "unknown protected branch error\n";
    if ( _is_gitlab_already_exists_error($protect_error) ) {
        return 1 if _get_protected_branch( $client, $project_id, $branch_name );
        die "protected branch missing after already-exists response: $branch_name\n";
    }
    die $protect_error;
}

sub _ensure_target_branch_unprotected {
    my ( $client, $project_id, $branch_name ) = @_;
    _gitlab_request(
        $client,
        "DELETE",
        "/projects/$project_id/protected_branches/" . _encode_path($branch_name),
        undef,
        { allow_missing => 1 }
    );
    return 1;
}

sub _list_gitlab_top_level_groups {
    my ( $client, $policy ) = @_;
    my @groups;
    my $page = 1;
    my $page_size = _gitlab_read_page_size($policy);
    my $request_opt = _gitlab_read_request_opt($policy);
    while (1) {
        my $path = sprintf(
            "/groups?top_level_only=true&per_page=%d&page=%d&order_by=path&sort=asc",
            $page_size,
            $page,
        );
        my $data = _gitlab_request( $client, "GET", $path, undef, $request_opt );
        ref($data) eq "ARRAY" or die "top-level groups response must be a list\n";
        last unless @{$data};
        push @groups, @{$data};
        last if @{$data} < $page_size;
        $page++;
    }
    return \@groups;
}

sub _resolve_source_auth_for_entry {
    my ( $source_auth, $entry ) = @_;
    if ( ( $entry->{source_auth_mode} || q{} ) eq "none" ) {
        return {
            token => undef,
            username => undef,
        };
    }
    my ( $base_url ) = _split_source_url( $entry->{source_http_url} );
    if ( _base_url_host($base_url) eq "github.com" ) {
        return _github_installation_source_auth(
            $source_auth,
            $base_url,
            $entry->{source_group_path},
            $entry->{policy},
        );
    }
    return {
        token => $source_auth->{token},
        username => $source_auth->{username},
    };
}

sub _github_installation_source_auth {
    my ( $source_auth, $base_url, $account, $policy ) = @_;
    my $github_app = $source_auth->{github_app}
      or die "GitHub source $account requires GH_ORG_READ_APP_ID and GH_ORG_READ_APP_PEM secrets\n";
    my $installation_key = defined $github_app->{install_id} ? $github_app->{install_id} : $account;
    my $cache_key = lc( $base_url . "|" . $installation_key );
    my $cached = $source_auth->{github_installation_tokens}->{$cache_key};
    if ( $cached && $cached->{expires_at_epoch} > time() + 300 ) {
        return {
            token => $cached->{token},
            username => "x-access-token",
        };
    }

    my $jwt = _generate_github_app_jwt( $github_app->{app_id}, $github_app->{pem} );
    my $installation =
      defined $github_app->{install_id}
      ? { id => $github_app->{install_id} }
      : _get_github_account_installation(
            $base_url,
            $account,
            $jwt,
            $policy,
        );
    my %request_opt = %{ _source_read_request_opt($policy) };
    $request_opt{auth_bearer} = $jwt;
    $request_opt{method} = "POST";
    my $token_payload = _github_request(
        $base_url,
        "/app/installations/" . $installation->{id} . "/access_tokens",
        undef,
        \%request_opt,
    );
    ref($token_payload) eq "HASH"
      or die "GitHub installation token response must be an object for $account\n";
    my $token = _required_string( $token_payload->{token}, "GitHub installation token" );
    my $expires_at = _required_string( $token_payload->{expires_at}, "GitHub installation token expires_at" );
    my $token_state = {
        expires_at_epoch => _parse_iso8601_utc_epoch($expires_at),
        token => $token,
    };
    $source_auth->{github_installation_tokens}->{$cache_key} = $token_state;
    return {
        token => $token_state->{token},
        username => "x-access-token",
    };
}

sub _get_github_account_installation {
    my ( $base_url, $account, $jwt, $policy ) = @_;
    my %request_opt = %{ _source_read_request_opt($policy) };
    $request_opt{allow_missing} = 1;
    $request_opt{auth_bearer} = $jwt;

    my $installation = _github_request(
        $base_url,
        "/orgs/" . uri_escape_utf8($account) . "/installation",
        undef,
        \%request_opt,
    );
    return $installation if $installation;

    $installation = _github_request(
        $base_url,
        "/users/" . uri_escape_utf8($account) . "/installation",
        undef,
        \%request_opt,
    );
    return $installation if $installation;

    die "GitHub App installation not found for source account $account\n";
}

sub _list_github_org_projects {
    my ( $base_url, $org_path, $policy, $source_auth ) = @_;
    my @projects;
    my $page = 1;
    my $page_size = 100;
    while (1) {
        my $path = sprintf(
            "/orgs/%s/repos?per_page=%d&page=%d&type=all&sort=full_name&direction=asc",
            uri_escape_utf8($org_path),
            $page_size,
            $page,
        );
        my %request_opt = %{ _source_read_request_opt($policy) };
        $request_opt{auth_bearer} = $source_auth->{token};
        my $data = _github_request( $base_url, $path, undef, \%request_opt );
        ref($data) eq "ARRAY" or die "GitHub org repositories response must be a list\n";
        last unless @{$data};
        for my $repo ( @{$data} ) {
            next unless ref($repo) eq "HASH";
            my $full_name = _required_github_full_name(
                $repo->{full_name},
                "GitHub repository full_name",
            );
            push @projects,
              {
                archived => $repo->{archived} ? JSON::PP::true : JSON::PP::false,
                default_branch => defined $repo->{default_branch} ? $repo->{default_branch} : q{},
                description => defined $repo->{description} ? $repo->{description} : q{},
                empty_repo => ( defined $repo->{size} && $repo->{size} == 0 ) ? JSON::PP::true : JSON::PP::false,
                http_url_to_repo => _required_https_url( $repo->{clone_url}, "GitHub clone_url" ),
                id => $repo->{id},
                lfs_enabled => JSON::PP::false,
                last_activity_at => $repo->{pushed_at} || $repo->{updated_at},
                path_with_namespace => $full_name,
                ssh_url_to_repo => $repo->{ssh_url} || $repo->{clone_url},
                visibility => defined $repo->{visibility}
                  ? $repo->{visibility}
                  : ( $repo->{private} ? "private" : "public" ),
              };
        }
        last if @{$data} < $page_size;
        $page++;
    }
    return \@projects;
}

sub _list_cgit_root_projects {
    my ( $base_url, $group_path, $policy ) = @_;
    return _list_root_index_projects(
        $base_url,
        $group_path,
        $policy,
        { allow_nested_paths => 0 },
    );
}

sub _list_root_index_projects {
    my ( $base_url, $group_path, $policy, $opt ) = @_;
    $opt ||= {};
    my $html = _http_text_request( $base_url, _source_read_request_opt($policy) );
    my @projects;
    my %seen;
    while ( $html =~ m{<a[^>]+href=(["'])([^"'?#]+)\1[^>]*>([^<]*)</a>}ig ) {
        my $repo_path = _extract_root_repo_path( $2, $3, $opt );
        next unless defined $repo_path;
        next if $seen{$repo_path}++;
        my $repo_url = $base_url . "/" . $repo_path;
        push @projects,
          {
            archived => JSON::PP::false,
            default_branch => q{},
            description => defined $3 && length $3 ? $3 : $repo_path,
            empty_repo => JSON::PP::false,
            http_url_to_repo => $repo_url,
            id => "cgit:$repo_url",
            lfs_enabled => JSON::PP::false,
            last_activity_at => undef,
            path_with_namespace => _join_path( $group_path, $repo_path ),
            ssh_url_to_repo => $repo_url,
            visibility => "public",
          };
    }
    @projects or die "root index discovery found no repositories at $base_url\n";
    return \@projects;
}

sub _list_group_projects {
    my ( $client, $group_path, $policy, $known_group ) = @_;
    if ( $policy && $policy->{gitlab_source_include_subgroups} ) {
        return _list_group_projects_include_subgroups( $client, $group_path, $policy, $known_group );
    }

    my $group = $known_group || _get_group( $client, $group_path, _gitlab_read_request_opt($policy) );
    return [] unless $group;

    my @projects;
    my @queue = ($group);
    my %seen_group_ids;
    my %seen_project_ids;

    while (@queue) {
        my $current = shift @queue;
        next unless ref($current) eq "HASH";
        my $group_id = $current->{id};
        next unless defined $group_id;
        next if $seen_group_ids{$group_id}++;

        for my $project ( @{ _list_direct_group_projects( $client, $group_id, $policy ) } ) {
            next unless ref($project) eq "HASH";
            my $project_id = $project->{id};
            next if defined $project_id && $seen_project_ids{$project_id}++;
            push @projects, $project;
        }

        push @queue, sort {
            ( lc( $a->{full_path} || $a->{path} || q{} ) )
              cmp
            ( lc( $b->{full_path} || $b->{path} || q{} ) )
        } @{ _list_group_subgroups( $client, $group_id, $policy ) };
    }

    return \@projects;
}

sub _list_group_projects_include_subgroups {
    my ( $client, $group_path, $policy, $known_group ) = @_;
    my $group = $known_group || _get_group( $client, $group_path, _gitlab_read_request_opt($policy) );
    return [] unless $group;

    my @projects;
    my %seen_project_ids;
    my $page = 1;
    my $page_size = _gitlab_read_page_size($policy);
    my $request_opt = _gitlab_read_request_opt($policy);
    while (1) {
        my $path = sprintf(
            "/groups/%s/projects?include_subgroups=true&with_shared=false&per_page=%d&page=%d",
            $group->{id},
            $page_size,
            $page,
        );
        my $data = _gitlab_request( $client, "GET", $path, undef, $request_opt );
        ref($data) eq "ARRAY" or die "group include_subgroups projects response must be a list\n";
        last unless @{$data};
        for my $project ( @{$data} ) {
            next unless ref($project) eq "HASH";
            my $project_id = $project->{id};
            next if defined $project_id && $seen_project_ids{$project_id}++;
            push @projects, $project;
        }
        last if @{$data} < $page_size;
        $page++;
    }
    return \@projects;
}

sub _list_direct_group_projects {
    my ( $client, $group_id, $policy ) = @_;
    my @projects;
    my $page = 1;
    my $page_size = _gitlab_read_page_size($policy);
    my $request_opt = _gitlab_read_request_opt($policy);
    while (1) {
        my $path = sprintf(
            "/groups/%s/projects?include_subgroups=false&with_shared=false&per_page=%d&page=%d",
            $group_id,
            $page_size,
            $page,
        );
        my $data = _gitlab_request( $client, "GET", $path, undef, $request_opt );
        ref($data) eq "ARRAY" or die "group projects response must be a list\n";
        last unless @{$data};
        push @projects, @{$data};
        last if @{$data} < $page_size;
        $page++;
    }
    return \@projects;
}

sub _list_group_subgroups {
    my ( $client, $group_id, $policy ) = @_;
    my @groups;
    my $page = 1;
    my $page_size = _gitlab_read_page_size($policy);
    my $request_opt = _gitlab_read_request_opt($policy);
    while (1) {
        my $path = sprintf(
            "/groups/%s/subgroups?per_page=%d&page=%d",
            $group_id,
            $page_size,
            $page,
        );
        my $data = _gitlab_request( $client, "GET", $path, undef, $request_opt );
        ref($data) eq "ARRAY" or die "group subgroups response must be a list\n";
        last unless @{$data};
        push @groups, @{$data};
        last if @{$data} < $page_size;
        $page++;
    }
    return \@groups;
}

sub _build_target_project_index {
    my ( $client, $group_path, $policy ) = @_;
    return _build_target_namespace_state( $client, $group_path, $policy )->{projects};
}

sub _build_target_namespace_state {
    my ( $client, $group_path, $policy ) = @_;
    my $request_opt = _gitlab_read_request_opt($policy);
    my $group = _get_group( $client, $group_path, $request_opt );
    return { groups => {}, projects => {} } unless $group;

    my %groups = (
        $group_path => $group->{id},
    );
    my %projects;
    my @queue = ($group);
    my %seen_group_ids;
    my %seen_project_ids;

    while (@queue) {
        my $current = shift @queue;
        next unless ref($current) eq "HASH";
        my $group_id = $current->{id};
        next unless defined $group_id;
        next if $seen_group_ids{$group_id}++;

        my $current_path = $current->{full_path} || q{};
        if ( defined $current_path && !ref($current_path) && length $current_path ) {
            $groups{$current_path} = $group_id;
        }

        for my $project ( @{ _list_direct_group_projects( $client, $group_id, $policy ) } ) {
            next unless ref($project) eq "HASH";
            my $project_id = $project->{id};
            next if defined $project_id && $seen_project_ids{$project_id}++;
            my $path = $project->{path_with_namespace};
            next unless defined $path && !ref($path) && length $path;
            $projects{$path} = $project;
        }

        my @subgroups = @{ _list_group_subgroups( $client, $group_id, $policy ) };
        for my $subgroup (@subgroups) {
            next unless ref($subgroup) eq "HASH";
            my $subgroup_path = $subgroup->{full_path} || q{};
            if ( defined $subgroup_path && !ref($subgroup_path) && length $subgroup_path ) {
                $groups{$subgroup_path} = $subgroup->{id};
            }
        }
        push @queue, sort {
            ( lc( $a->{full_path} || $a->{path} || q{} ) )
              cmp
            ( lc( $b->{full_path} || $b->{path} || q{} ) )
        } @subgroups;
    }

    return {
        groups => \%groups,
        projects => \%projects,
    };
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
    if ( !$default_branch ) {
        $default_branch = _infer_default_branch_from_heads( \%branches );
    }
    return {
        branches => \%branches,
        default_branch => $default_branch,
        tags => \%tags,
    };
}

sub _infer_default_branch_from_heads {
    my ($branches) = @_;
    return q{} unless $branches && ref($branches) eq "HASH";
    return "main" if $branches->{main};
    return "master" if $branches->{master};
    my @names = sort keys %{$branches};
    return $names[0] if @names == 1;
    return q{};
}

sub _fetch_selected_refs {
    my ( $repo_dir, $selected, $policy ) = @_;
    for my $branch ( @{ $selected->{branches} || [] } ) {
        my $remote_ref = "refs/remotes/source/$branch";
        my $result = _run_command(
            [
                "git", "-C", $repo_dir, "fetch", "--no-tags", "source",
                "+refs/heads/$branch:$remote_ref"
            ],
            _git_command_options( $policy, JSON::PP::true )
        );
        $result->{status} == 0 or die "git fetch failed for branch $branch: $result->{output}\n";
        $result = _run_command(
            [ "git", "-C", $repo_dir, "update-ref", "refs/heads/$branch", $remote_ref ],
            {
                timeout => 120,
            }
        );
        $result->{status} == 0 or die "git update-ref failed for branch $branch: $result->{output}\n";
    }
    for my $tag ( @{ $selected->{tags} || [] } ) {
        my $result = _run_command(
            [
                "git", "-C", $repo_dir, "fetch", "--no-tags", "source",
                "+refs/tags/$tag:refs/tags/$tag"
            ],
            _git_command_options( $policy, JSON::PP::true )
        );
        $result->{status} == 0 or die "git fetch failed for tag $tag: $result->{output}\n";
    }
}

sub _push_selected_refs {
    my ( $repo_dir, $selected, $policy, $default_branch ) = @_;
    my %additional_branch_names = map { $_->{name} => 1 } @{ $policy->{additional_branches} || [] };
    for my $branch ( @{ $selected->{branches} || [] } ) {
        next if $default_branch && $branch eq $default_branch && !$additional_branch_names{$branch};
        _push_target_refspec(
            $repo_dir,
            "refs/heads/$branch:refs/heads/$branch",
            "branch $branch",
            $policy,
        );
    }
    if ($default_branch) {
        _push_target_refspec(
            $repo_dir,
            "refs/heads/$default_branch:refs/heads/$TARGET_SYNC_BRANCH",
            "managed sync branch $TARGET_SYNC_BRANCH",
            $policy,
        );
    }
    for my $tag ( @{ $selected->{tags} || [] } ) {
        _push_target_refspec(
            $repo_dir,
            "refs/tags/$tag:refs/tags/$tag",
            "tag $tag",
            $policy,
        );
    }
}

sub _push_target_refspec {
    my ( $repo_dir, $refspec, $label, $policy ) = @_;
    my $result = _run_command(
        [
            "git", "-C", $repo_dir, "push", "--force", "target",
            $refspec
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
                $refspec
            ],
            _git_command_options( $policy, JSON::PP::true )
        );
    }
    $result->{status} == 0 or die "git push failed for $label: $result->{output}\n";
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
    my $attempts = $opt->{retry_attempts} || $DEFAULTS{retry_attempts};
    my $backoff = $opt->{retry_backoff_seconds} || $DEFAULTS{retry_backoff_seconds};
    my $max_time = $opt->{max_time_seconds} || 60;
    my $timeout = $opt->{timeout_seconds} || 90;
    my $content = defined $payload ? $JSON->encode($payload) : undef;
    for my $attempt ( 1 .. $attempts ) {
        my @command = (
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--max-time",
            $max_time,
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
                timeout => $timeout,
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
                || _is_retryable_gitlab_http_error( $http_status, $body )
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

sub _is_retryable_gitlab_http_error {
    my ( $http_status, $body ) = @_;
    return 1 if $http_status == 408;
    return 1 if $http_status == 429;
    return 1 if $http_status >= 500;
    return 0 unless defined $body && !ref($body) && length $body;
    return 1 if $body =~ /request timed out/i;
    return 1 if $body =~ /timed out/i && $body =~ /please try again/i;
    return 0;
}

sub _github_request {
    my ( $base_url, $path, $payload, $opt ) = @_;
    $opt ||= {};
    my $url = _github_api_base_url($base_url) . $path;
    my $attempts = $opt->{retry_attempts} || $DEFAULTS{retry_attempts};
    my $backoff = $opt->{retry_backoff_seconds} || $DEFAULTS{retry_backoff_seconds};
    my $max_time = $opt->{max_time_seconds} || 60;
    my $method = $opt->{method} || ( defined $payload ? "POST" : "GET" );
    my $timeout = $opt->{timeout_seconds} || 90;
    my $content = defined $payload ? $JSON->encode($payload) : undef;
    for my $attempt ( 1 .. $attempts ) {
        my @command = (
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--max-time",
            $max_time,
            "--request",
            $method,
            "--header",
            "Accept: application/vnd.github+json",
            "--header",
            "User-Agent: glab-groups-shared",
            "--write-out",
            "\n%{http_code}",
            $url,
        );
        if ( $opt->{auth_bearer} ) {
            push @command, "--header", "Authorization: Bearer " . $opt->{auth_bearer};
        }
        for my $header ( @{ $opt->{headers} || [] } ) {
            push @command, "--header", $header;
        }
        if ( defined $content ) {
            push @command, "--header", "Content-Type: application/json", "--data", $content;
        }

        my $response = _run_command(
            \@command,
            {
                timeout => $timeout,
            }
        );

        my ( $http_status, $body ) = _split_curl_response( $response->{output} );
        if ( $response->{status} == 0 && $http_status >= 200 && $http_status < 300 ) {
            return undef if !defined $body || $body eq q{};
            return _decode_json_response( $body, "GET", $path );
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
        die "GitHub request failed [$status_label] $path: $message\n";
    }
    die "GitHub request exhausted retries for $path\n";
}

sub _github_api_base_url {
    my ($base_url) = @_;
    return "https://api.github.com" if _base_url_host($base_url) eq "github.com";
    return $base_url . "/api/v3";
}

sub _http_text_request {
    my ( $url, $opt ) = @_;
    $opt ||= {};
    my $attempts = $opt->{retry_attempts} || $DEFAULTS{retry_attempts};
    my $backoff = $opt->{retry_backoff_seconds} || $DEFAULTS{retry_backoff_seconds};
    my $max_time = $opt->{max_time_seconds} || 60;
    my $timeout = $opt->{timeout_seconds} || 90;
    for my $attempt ( 1 .. $attempts ) {
        my $response = _run_command(
            [
                "curl",
                "--silent",
                "--show-error",
                "--location",
                "--max-time",
                $max_time,
                "--header",
                "User-Agent: glab-groups-shared",
                "--write-out",
                "\n%{http_code}",
                $url,
            ],
            {
                timeout => $timeout,
            }
        );

        my ( $http_status, $body ) = _split_curl_response( $response->{output} );
        if ( $response->{status} == 0 && $http_status >= 200 && $http_status < 300 ) {
            return $body;
        }

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
        die "HTTP request failed [$status_label] $url: $message\n";
    }
    die "HTTP request exhausted retries for $url\n";
}

sub _gitlab_read_page_size {
    return $GITLAB_READ_DEFAULTS{page_size};
}

sub _gitlab_read_request_opt {
    my ($policy) = @_;
    my $retry_attempts = $GITLAB_READ_DEFAULTS{retry_attempts};
    my $retry_backoff = $GITLAB_READ_DEFAULTS{retry_backoff_seconds};
    if ( $policy && ref($policy) eq "HASH" ) {
        $retry_attempts = $policy->{read_retry_attempts}
          if $policy->{read_retry_attempts};
        $retry_backoff = $policy->{read_retry_backoff_seconds}
          if $policy->{read_retry_backoff_seconds};
    }
    return {
        max_time_seconds => $GITLAB_READ_DEFAULTS{max_time_seconds},
        retry_attempts => $retry_attempts,
        retry_backoff_seconds => $retry_backoff,
        timeout_seconds => $GITLAB_READ_DEFAULTS{timeout_seconds},
    };
}

sub _source_read_request_opt {
    my ($policy) = @_;
    return _gitlab_read_request_opt($policy);
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

sub _generate_github_app_jwt {
    my ( $app_id, $pem_text ) = @_;
    my ( $key_fh, $key_path ) = tempfile();
    print {$key_fh} $pem_text;
    close $key_fh;

    my $header = _base64url_encode_json(
        {
            alg => "RS256",
            typ => "JWT",
        }
    );
    my $now = time();
    my $payload = _base64url_encode_json(
        {
            exp => $now + 540,
            iat => $now,
            iss => $app_id,
        }
    );
    my $unsigned = $header . "." . $payload;
    my ( $unsigned_fh, $unsigned_path ) = tempfile();
    binmode $unsigned_fh;
    print {$unsigned_fh} $unsigned;
    close $unsigned_fh;

    my $sign_result = _run_command(
        [
            "openssl",
            "dgst",
            "-binary",
            "-sha256",
            "-sign",
            $key_path,
            $unsigned_path,
        ],
        {
            timeout => 60,
        }
    );
    unlink $key_path;
    unlink $unsigned_path;
    $sign_result->{status} == 0 or die "GitHub App JWT signing failed: $sign_result->{output}\n";
    return $unsigned . "." . _base64url_encode_bytes( $sign_result->{output} );
}

sub _base64url_encode_json {
    my ($payload) = @_;
    return _base64url_encode_bytes( $JSON->encode($payload) );
}

sub _base64url_encode_bytes {
    my ($value) = @_;
    my $encoded = encode_base64( $value, q{} );
    $encoded =~ tr{+/}{-_};
    $encoded =~ s/=+\z//;
    return $encoded;
}

sub _parse_iso8601_utc_epoch {
    my ($value) = @_;
    my $text = _required_string( $value, "timestamp" );
    my $parsed = eval {
        Time::Piece->strptime( $text, "%Y-%m-%dT%H:%M:%SZ" )->epoch;
    };
    defined $parsed or die "invalid UTC timestamp: $text\n";
    return $parsed;
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

sub _read_jsonl {
    my ($path) = @_;
    open( my $fh, "<:encoding(UTF-8)", $path ) or die "unable to read $path\n";
    my @rows;
    while ( my $line = <$fh> ) {
        $line =~ s/\s+\z//;
        next unless length $line;
        push @rows, $JSON->decode($line);
    }
    close $fh;
    return \@rows;
}

sub _read_config_payload {
    my ($path) = @_;
    return _read_json($path) if $path =~ /\.json\z/;

    open( my $fh, "<:encoding(UTF-8)", $path ) or die "unable to read $path\n";
    my $text = do { local $/; <$fh> };
    close $fh;

    if ( $path =~ /projects\.ya?ml\z/ ) {
        my $candidate = defined $text ? $text : q{};
        $candidate =~ s/^\s*#.*\n//mg;
        $candidate =~ s/\A\s+//;
        $candidate =~ s/\s+\z//;
        return [] if !length $candidate || $candidate eq '[]';
    }

    my $docs = CPAN::Meta::YAML->read_string($text)
      or die "unable to parse YAML config: $path\n";
    eval { @{$docs} == 1 }
      or die "config file must contain exactly one YAML document: $path\n";
    return $docs->[0];
}

sub _config_authoritative_projects_by_target_full_path {
    my ($config) = @_;
    if ( ref( $config->{authoritative_projects_by_target_full_path} ) eq "HASH" ) {
        return $config->{authoritative_projects_by_target_full_path};
    }
    my %targets;
    for my $project ( @{ $config->{projects} || [] } ) {
        my $target_paths = _resolve_explicit_project_target_paths($project);
        my $target_full_path = $target_paths->{target_full_path};
        die "duplicate authoritative projects.yml target path: $target_full_path\n"
          if exists $targets{$target_full_path};
        $targets{$target_full_path} = $project;
    }
    $config->{authoritative_projects_by_target_full_path} = \%targets
      if ref($config) eq "HASH";
    return \%targets;
}

sub _config_exclusion_reason {
    my ( $config, $target_relative_project_path, $target_full_path ) = @_;
    return undef unless ref( $config->{exclusions} ) eq "HASH";
    return $config->{exclusions}->{$target_full_path}
      if exists $config->{exclusions}->{$target_full_path};
    return $config->{exclusions}->{$target_relative_project_path}
      if exists $config->{exclusions}->{$target_relative_project_path};
    return undef;
}

sub _resolve_explicit_project_target_paths {
    my ( $project, $namespace ) = @_;
    my $target_namespace_path = _required_relative_namespace_path(
        $project->{target_group_path},
        "target_group_path",
    );
    my $target_full_path = _join_path(
        $target_namespace_path,
        _required_path_segment( $project->{name}, "project.name" ),
    );
    my $target_relative_project_path = $target_full_path;

    if ( ref($namespace) eq "HASH" ) {
        my $target_owner_path = $namespace->{target_owner_path};
        if ( defined $target_owner_path && !ref($target_owner_path) && length $target_owner_path ) {
            my $normalized_owner_path = _required_relative_namespace_path(
                $target_owner_path,
                "target_owner_path",
            );
            my $prefix = $normalized_owner_path . "/";
            if ( index( $target_full_path, $prefix ) == 0 ) {
                $target_relative_project_path =
                  substr( $target_full_path, length($prefix) );
            }
        }
    }

    return {
        target_full_path => $target_full_path,
        target_relative_project_path => $target_relative_project_path,
        target_namespace_path => $target_namespace_path,
    };
}

sub _resolve_namespace_project_target_paths {
    my ( $namespace, $source_group_path, $source_full_path ) = @_;
    my $target_root_path = _resolve_target_root_group_path($namespace);
    my $relative_path = _relative_path( $source_group_path, $source_full_path );
    my $target_relative_project_path =
      _join_path( $namespace->{target_namespace_path}, $relative_path );
    my $target_full_path = _join_path( $target_root_path, $target_relative_project_path );
    return {
        target_full_path => $target_full_path,
        target_relative_project_path => $target_relative_project_path,
        target_namespace_path => dirname($target_full_path),
    };
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

sub _required_numeric_string {
    my ( $value, $label ) = @_;
    $value = _required_string( $value, $label );
    $value =~ /\A\d+\z/ or die "$label must contain digits only\n";
    return $value;
}

sub _required_project_path {
    my ( $value, $label ) = @_;
    return _required_group_path_min_segments( $value, $label, 2 );
}

sub _required_github_full_name {
    my ( $value, $label ) = @_;
    $value = _required_string( $value, $label );
    my @segments = split m{/}, $value;
    @segments == 2 or die "$label must contain exactly two path segments\n";
    $segments[0] =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
      or die "$label owner must be a GitHub account path segment\n";
    $segments[1] =~ /\A[A-Za-z0-9._-]+\z/
      or die "$label repository must be a GitHub repository name\n";
    return $value;
}

sub _required_relative_namespace_path {
    my ( $value, $label ) = @_;
    return _required_group_path_min_segments( $value, $label, 1 );
}

sub _required_relative_project_path {
    my ( $value, $label ) = @_;
    return _required_group_path_min_segments( $value, $label, 2 );
}

sub _required_path_segment {
    my ( $value, $label ) = @_;
    $value = _required_string( $value, $label );
    $value =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
      or die "$label must be a single path segment\n";
    return $value;
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

sub _required_secret_name {
    my ( $value, $label ) = @_;
    $value = _required_string( $value, $label );
    $value =~ /\AGL_PAT_GROUP_[A-Z0-9_]+_SVC\z/
      or die "$label must name a GL_PAT_GROUP_*_SVC secret\n";
    return $value;
}

sub _normalize_private_key_secret {
    my ( $value, $label ) = @_;
    my $normalized = _required_string( $value, $label );
    if ( $normalized !~ /-----BEGIN [A-Z ]+ PRIVATE KEY-----/ ) {
        my $decoded = eval { decode_base64($normalized) };
        if ( defined $decoded && $decoded =~ /-----BEGIN [A-Z ]+ PRIVATE KEY-----/ ) {
            $normalized = $decoded;
        }
    }
    $normalized =~ s/\\n/\n/g;
    $normalized =~ s/\r//g;
    $normalized =~ /-----BEGIN [A-Z ]+ PRIVATE KEY-----/
      or die "$label must contain a PEM-encoded private key\n";
    $normalized .= "\n" unless $normalized =~ /\n\z/;
    return $normalized;
}

sub _reject_visibility_key {
    my ( $payload, $label ) = @_;
    return unless exists $payload->{visibility};
    die "$label.visibility is no longer supported; manage target visibility outside this workflow\n";
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
    $relative =~ /\A[A-Za-z0-9.][A-Za-z0-9._-]*(?:\/[A-Za-z0-9.][A-Za-z0-9._-]*)*\z/
      or die "invalid relative project path: $relative\n";
    for my $segment ( split m{/}, $relative ) {
        $segment ne "." && $segment ne ".."
          or die "invalid relative project path: $relative\n";
    }
    return $relative;
}

sub _gitlab_invalid_target_path_reason {
    my ($path) = @_;
    $path = _required_string( $path, "target_full_path" );
    for my $segment ( split m{/}, $path ) {
        my $reason = _gitlab_invalid_path_segment_reason($segment);
        next unless defined $reason;
        return "Target GitLab path segment '$segment' is invalid: $reason";
    }
    return undef;
}

sub _gitlab_invalid_path_segment_reason {
    my ($segment) = @_;
    $segment = _required_string( $segment, "target path segment" );
    return "path segments may contain only ASCII letters, digits, '_', '-', and '.'"
      if $segment !~ /\A[A-Za-z0-9._-]+\z/;
    return "path segments must not start with '-', '_', or '.'"
      if $segment =~ /\A[-_.]/;
    return "path segments must not end with '-', '_', '.', '.git', or '.atom'"
      if $segment =~ /(?:[-_.]|\.(?:git|atom))\z/i;
    return undef;
}

sub _strip_optional_git_suffix {
    my ($value) = @_;
    my $normalized = _required_string( $value, "project path segment" );
    $normalized =~ s/\.git\z//;
    return $normalized;
}

sub _join_path {
    my ( $left, $right ) = @_;
    return $left . "/" . $right;
}

sub _split_source_url {
    my ($url) = @_;
    $url = _required_https_url( $url, "source_group_url" );
    $url =~ /\A(https:\/\/[A-Za-z0-9.-]+(?::\d+)?)(?:\/([^?#]+))?\z/
      or die "invalid source URL: $url\n";
    my $base = $1;
    my $path = defined $2 ? $2 : q{};
    $path =~ s{/\z}{};
    if ( length $path ) {
        $path =~ /\A(?:~?[A-Za-z0-9][A-Za-z0-9._-]*)(?:\/(?:~?[A-Za-z0-9][A-Za-z0-9._-]*))*\z/
          or die "invalid source URL path: $url\n";
    }
    return ( $base, $path );
}

sub _base_url_host {
    my ($base_url) = @_;
    $base_url =~ /\Ahttps:\/\/([^\/:]+)(?::\d+)?\z/
      or die "invalid base URL: $base_url\n";
    return lc($1);
}

sub _is_gitlab_instance_root {
    my ( $base_url, $policy ) = @_;
    my $client = _make_gitlab_client( $base_url, undef, undef );
    my $ok = eval {
        my $groups = _gitlab_request(
            $client,
            "GET",
            "/groups?top_level_only=true&per_page=1&page=1&order_by=path&sort=asc",
            undef,
            _source_read_request_opt($policy),
        );
        ref($groups) eq "ARRAY" or die "GitLab root probe did not return a list\n";
        1;
    };
    return $ok ? 1 : 0;
}

sub _is_gitiles_host {
    my ($base_url) = @_;
    my $host = _base_url_host($base_url);
    return $host =~ /(?:^|\.)googlesource\.com\z/ ? 1 : 0;
}

sub _source_root_key {
    my ($base_url) = @_;
    my $host = _base_url_host($base_url);
    $host =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/
      or die "unable to derive source root key from $base_url\n";
    return $host;
}

sub _has_discoverable_refs {
    my ($available) = @_;
    return 0 unless ref($available) eq "HASH";
    return 1 if scalar( keys %{ $available->{branches} || {} } );
    return 1 if scalar( keys %{ $available->{tags} || {} } );
    return length( $available->{default_branch} || q{} ) ? 1 : 0;
}

sub _discover_remote_refs_from_urls {
    my ( $candidate_urls, $policy, $chosen_source_url_ref ) = @_;
    ref($candidate_urls) eq "ARRAY" or die "candidate source URLs must be a list\n";
    my %seen;
    my @candidates = grep { defined $_ && length $_ && !$seen{$_}++ } @{$candidate_urls};
    @candidates or die "at least one candidate source URL is required\n";

    my $fallback_success;
    my $fallback_success_url = q{};
    my $last_error = q{};
    for my $candidate (@candidates) {
        my $available = eval { _discover_remote_refs( $candidate, $policy ) };
        if ($available) {
            if ( _has_discoverable_refs($available) ) {
                $$chosen_source_url_ref = $candidate if defined $chosen_source_url_ref;
                return $available;
            }
            if ( !$fallback_success ) {
                $fallback_success = $available;
                $fallback_success_url = $candidate;
            }
            next;
        }
        $last_error ||= $@;
    }

    if ($fallback_success) {
        $$chosen_source_url_ref = $fallback_success_url if defined $chosen_source_url_ref;
        return $fallback_success;
    }

    die $last_error if length $last_error;
    die "unable to discover source refs from the configured candidate URLs\n";
}

sub _maybe_auth_url {
    my ( $url, $username, $token ) = @_;
    return $url unless defined $url && length $url;
    return $url unless $username && $token;
    $url =~ /\Ahttps:\/\/([^\/]+)(\/.*)\z/ or return $url;
    return "https://" . uri_escape_utf8($username) . ":" . uri_escape_utf8($token) . "\@$1$2";
}

sub _strip_auth_from_url {
    my ($url) = @_;
    return $url unless defined $url && length $url;
    $url =~ s{\A(https://)[^/@]+@}{$1};
    return $url;
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
    $error = "unknown error" unless defined $error;
    $error =~ s/\s+\z//;
    return $error;
}

sub _sanitize_payload {
    my ($value) = @_;
    return _redact_secret_material($value) if !ref($value);
    if ( ref($value) eq "HASH" ) {
        return { map { $_ => _sanitize_payload( $value->{$_} ) } keys %{$value} };
    }
    if ( ref($value) eq "ARRAY" ) {
        return [ map { _sanitize_payload($_) } @{$value} ];
    }
    return $value;
}

sub _redact_secret_material {
    my ($value) = @_;
    return $value unless defined $value;
    my $text = $value;
    $text =~ s{https://[^/\s:@]+:[^@\s/]+@}{https://<redacted>@}g;
    $text =~ s{(PRIVATE-TOKEN:\s*)\S+}{$1<redacted>}ig;
    $text =~ s{\bglpat-[A-Za-z0-9._-]+\b}{glpat-<redacted>}g;
    $text =~ s{\bgithub_pat_[A-Za-z0-9_]+\b}{github_pat_<redacted>}g;
    $text =~ s{\bgh[opsu]_[A-Za-z0-9_]+\b}{gh_<redacted>}g;
    return $text;
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
