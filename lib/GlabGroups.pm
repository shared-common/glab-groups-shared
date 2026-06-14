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
my $TARGET_GIT_HTTPS_USERNAME = "0auth";

my %DEFAULTS = (
    allow_blob_rewrite => JSON::PP::true,
    batch_size => 10,
    force_lfs => JSON::PP::false,
    git_timeout_seconds => 1800,
    max_blob_bytes => 100 * 1024 * 1024,
    max_parallel => 5,
    mirror_pristine_tar => JSON::PP::false,
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
my $TARGET_NAMESPACE_STATE_CACHE_MIN_TARGETS = 3;

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
    my ( $config_dir, $opt ) = @_;
    $opt ||= {};
    defined $config_dir && -d $config_dir or die "config dir not found: $config_dir\n";

    opendir( my $dh, $config_dir ) or die "unable to read config dir: $config_dir\n";
    my @files = sort grep { /\.(?:json|jsonl|ya?ml)\z/ && -f File::Spec->catfile( $config_dir, $_ ) } readdir($dh);
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
        source_group_exclusions => {},
        source_group_paths => [],
    );

    for my $file (@files) {
        my $payload = _read_config_payload( File::Spec->catfile( $config_dir, $file ) );
        if ( $file eq "groups.jsonl" ) {
            next if $opt->{projects_only};
            ref($payload) eq "ARRAY" or die "groups.jsonl must be a JSONL list\n";
            @{$payload} or die "groups.jsonl must not be empty\n";
            for my $index ( 0 .. $#{$payload} ) {
                push @{ $config{source_group_paths} },
                  _normalize_source_group_path( $payload->[$index], "groups.jsonl[$index]" );
            }
            next;
        }
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
            next if $opt->{projects_only};
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
            my $source_groups = $payload->{source_groups} || [];
            ref($source_groups) eq "ARRAY" or die "$file.source_groups must be a list\n";
            for my $index ( 0 .. $#{$source_groups} ) {
                my $item = $source_groups->[$index];
                ref($item) eq "HASH" or die "$file.source_groups[$index] must be an object\n";
                my $path = _normalize_source_group_path( $item, "$file.source_groups[$index]" );
                my $reason = _required_string(
                    $item->{reason} || "Excluded source group by config",
                    "$file.source_groups[$index].reason"
                );
                $config{source_group_exclusions}->{$path} = $reason;
            }
            next;
        }

        die "unsupported config kind in $file: $kind\n";
    }

    ( $opt->{allow_empty} && $opt->{projects_only} )
      || @{ $config{namespaces} } || @{ $config{projects} }
      or die "config dir must contain at least one namespace root or explicit project\n";
    if ( @{ $config{source_group_paths} } ) {
        @{ $config{namespaces} } == 1
          or die "groups.jsonl requires exactly one namespace root in the config dir\n";
        my %seen_paths;
        for my $path ( @{ $config{source_group_paths} } ) {
            $seen_paths{$path}++
              and die "duplicate source group path in groups.jsonl: $path\n";
        }
        $config{namespaces}->[0]->{source_group_paths} =
          [ @{ $config{source_group_paths} } ];
    }
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
    my %opt = (
        output => "discover.json",
        unit_limit => 0,
        unit_start => 0,
        unit_stride => 1,
    );
    GetOptionsFromArray(
        \@argv,
        "config-dir=s" => \$opt{config_dir},
        "output=s" => \$opt{output},
        "projects-only!" => \$opt{projects_only},
        "unit-limit=i" => \$opt{unit_limit},
        "unit-start=i" => \$opt{unit_start},
        "unit-stride=i" => \$opt{unit_stride},
    ) or die _usage();
    $opt{unit_limit} >= 0 or die "unit-limit must be zero or greater\n";
    $opt{unit_start} >= 0 or die "unit-start must be zero or greater\n";
    $opt{unit_stride} > 0 or die "unit-stride must be greater than zero\n";

    my $config = load_config_dir(
        $opt{config_dir},
        {
            allow_empty => $opt{projects_only},
            projects_only => $opt{projects_only},
        }
    );
    my $inventory = _discover_inventory(
        $config,
        {
            unit_limit => $opt{unit_limit},
            unit_start => $opt{unit_start},
            unit_stride => $opt{unit_stride},
        }
    );
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
        discover_inputs => [],
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
        "discover-input=s@" => $opt{discover_inputs},
        "output=s" => \$opt{output},
        "projects-only!" => \$opt{projects_only},
        "summary=s" => \$opt{summary},
    ) or die _usage();
    $opt{max_batches} >= 0 or die "max-batches must be zero or greater\n";

    my $config = load_config_dir(
        $opt{config_dir},
        {
            allow_empty => $opt{projects_only},
            projects_only => $opt{projects_only},
        }
    );
    my $normalized;
    if ( @{ $opt{discover_inputs} || [] } ) {
        $normalized = _normalize_inventory(
            _merge_discover_payloads(
                [ map { _read_json($_) } @{ $opt{discover_inputs} } ]
            )
        );
    }
    else {
        warn "performing live inventory discovery\n";
        $normalized = _normalize_inventory( _discover_inventory($config) );
    }
    _write_json( $opt{discover_output}, $normalized ) if $opt{discover_output};
    my $plan = _build_plan(
        $config,
        $normalized,
        $opt{batch_size},
        {
            max_batches => $opt{max_batches},
        },
    );
    if ( ref( $normalized->{missing_source_groups} ) eq "ARRAY" && @{ $normalized->{missing_source_groups} } ) {
        $plan->{missing_source_groups} = [ @{ $normalized->{missing_source_groups} } ];
    }
    if ( ref( $normalized->{excluded_source_groups} ) eq "ARRAY" && @{ $normalized->{excluded_source_groups} } ) {
        $plan->{excluded_source_groups} = [ @{ $normalized->{excluded_source_groups} } ];
    }
    $plan->{total_targets} > 0
      || (
        ref( $plan->{missing_source_groups} ) eq "ARRAY"
        && @{ $plan->{missing_source_groups} }
      )
      || (
        ref( $plan->{excluded_source_groups} ) eq "ARRAY"
        && @{ $plan->{excluded_source_groups} }
      )
      || $opt{projects_only}
      or die "discovery produced zero targets; refusing to continue with a no-op mirror plan\n";
    _write_json( $opt{output}, $plan );
    _write_text( $opt{summary}, _render_plan_summary($plan) );
    return 0;
}

sub _build_group_batches {
    my ( $plan, $batch_count ) = @_;
    $batch_count >= 0 or die "batch-count must be zero or greater\n";
    my @entries = @{ $plan || [] };
    my $total_targets = scalar @entries;
    my %seen_groups = map { ( ( $_->{target_namespace_path} || q{} ) => 1 ) } @entries;
    return ( [], scalar keys %seen_groups ) if !$total_targets;

    $batch_count = 1 if $batch_count < 1;
    $batch_count = $total_targets if $batch_count > $total_targets;

    my $base_targets_per_batch = int( $total_targets / $batch_count );
    my $extra_targets = $total_targets % $batch_count;
    my @batches;
    my $start_index = 0;

    for my $batch_index ( 0 .. $batch_count - 1 ) {
        my $target_count =
          $base_targets_per_batch + ( $batch_index < $extra_targets ? 1 : 0 );
        next if $target_count <= 0;
        my $end_index = $start_index + $target_count - 1;
        my %group_paths;
        for my $entry_index ( $start_index .. $end_index ) {
            my $group_path = $entries[$entry_index]->{target_namespace_path} || q{};
            $group_paths{$group_path} = 1;
        }
        push @batches,
          {
            end_index => $end_index,
            group_paths => [ sort keys %group_paths ],
            start_index => $start_index,
            target_count => $target_count,
          };
        $start_index = $end_index + 1;
    }

    return ( \@batches, scalar keys %seen_groups );
}

sub _plan_group_priority_key {
    my ($entry) = @_;
    return q{} unless ref($entry) eq "HASH";
    return $entry->{source_group_path}
      if defined $entry->{source_group_path} && !ref( $entry->{source_group_path} ) && length $entry->{source_group_path};
    return $entry->{target_namespace_path}
      if defined $entry->{target_namespace_path} && !ref( $entry->{target_namespace_path} ) && length $entry->{target_namespace_path};
    return $entry->{target_full_path}
      if defined $entry->{target_full_path} && !ref( $entry->{target_full_path} ) && length $entry->{target_full_path};
    return q{};
}

sub _select_effective_batch_size {
    my ( $plan, $batch_size, $max_batches ) = @_;
    $batch_size > 0 or die "batch-size must be greater than zero\n";

    my $total_targets = scalar @{ $plan || [] };
    my $total_groups = scalar keys %{
        {
            map { ( ( $_->{target_namespace_path} || q{} ) => 1 ) } @{ $plan || [] }
        }
    };
    return ( $batch_size, [], $total_groups ) if !$total_targets;

    my $requested_batch_count =
      int( ( $total_targets + $batch_size - 1 ) / $batch_size );
    $requested_batch_count = 1 if $requested_batch_count < 1;
    if ($max_batches) {
        $requested_batch_count = $max_batches
          if $requested_batch_count > $max_batches;
    }
    $requested_batch_count = $total_targets
      if $requested_batch_count > $total_targets;

    my ( $batches, $seen_groups ) =
      _build_group_batches( $plan, $requested_batch_count );
    my $effective_batch_size = 0;
    for my $batch ( @{$batches} ) {
        next unless ref($batch) eq "HASH";
        my $target_count = $batch->{target_count} || 0;
        $effective_batch_size = $target_count
          if $target_count > $effective_batch_size;
    }
    $effective_batch_size ||= $batch_size;

    return ( $effective_batch_size, $batches, $seen_groups );
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
    my @failed;
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
            my @batch_entries = @entries[ $start .. $end ];
            _configure_target_namespace_state_cache_for_entries( $client, \@batch_entries );

	            for my $index ( $start .. $end ) {
		                my $entry = $entries[$index];
		                next if $entry->{action} eq "skip" || $entry->{action} eq "fail";
		                my ( $prepared, $failed ) = _prepare_target_entry_result( $client, $entry );
	                push @prepared, $prepared if $prepared;
	                push @failed, $failed if $failed;
	            }
	            $processed_batches++;
	        }
	    }
	    else {
	        _configure_target_namespace_state_cache_for_entries( $client, \@entries );
	        for my $entry (@entries) {
	            next if $entry->{action} eq "skip" || $entry->{action} eq "fail";
	            my ( $prepared, $failed ) = _prepare_target_entry_result( $client, $entry );
	            push @prepared, $prepared if $prepared;
	            push @failed, $failed if $failed;
	        }
	    }
    _write_json(
        $opt{output},
        {
            batch_start => $opt{batch_start},
            batch_stride => $opt{batch_stride},
            batch_limit => $opt{batch_limit},
            failure_count => scalar @failed,
            failures => \@failed,
            processed_batches => $processed_batches,
            prepared_count => scalar @prepared,
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
        prepared => "",
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
        "prepared=s" => \$opt{prepared},
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
    my ( $prepared_by_target, $prepare_failures_by_target ) =
      _index_prepared_payload( $opt{prepared} ? _read_json( $opt{prepared} ) : undef );

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
        my @batch_entries = @entries[ $start .. $end ];
        _configure_target_namespace_state_cache_for_entries( $target_client, \@batch_entries );

        for my $index ( $start .. $end ) {
            my $entry = $entries[$index];
            my $prepared = $prepared_by_target->{ $entry->{target_full_path} };
            my $prepare_failure = $prepare_failures_by_target->{ $entry->{target_full_path} };
            my $result;
            if ($prepare_failure) {
                $result = {
                    target_full_path => $entry->{target_full_path},
                    planned_action => $entry->{action},
                    status => "failed",
                    reason => "Repository skipped after target preparation failed in this shard.",
                    error => $prepare_failure->{error},
                };
            }
            elsif ( $entry->{action} ne "skip" && $entry->{action} ne "fail" && _gitlab_client_blocked_error($target_client) ) {
                $result = _blocked_target_result(
                    $entry,
                    _gitlab_client_blocked_error($target_client),
                    "mirror",
                );
            }
            else {
                $result = eval { _mirror_entry( $target_client, $source_auth, $entry, $prepared ) };
                if ($@) {
                    $result =
                        _gitlab_client_blocked_error($target_client)
                      ? _blocked_target_result(
                            $entry,
                            _gitlab_client_blocked_error($target_client),
                            "mirror",
                        )
                      : {
                            target_full_path => $entry->{target_full_path},
                            planned_action => $entry->{action},
                            status => "failed",
                            reason => "Repository failed after unrecoverable mirror error.",
                            error => _trim_error($@),
                        };
                }
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
    my $target_sync_branch = $client->{sync_branch};
    my @results;
    for my $entry ( @{ $plan->{plan} || [] } ) {
        push @results, _verify_entry( $client, $entry, undef, undef, $target_sync_branch );
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
    my @input_failures;
    for my $file (@result_files) {
        my $results = eval { _read_json($file) };
        if ($@) {
            push @input_failures,
              {
                error => _trim_error($@),
                file => $file,
              };
            next;
        }
        push @rows, grep { ref($_) eq "HASH" } @{ $results->{results} || [] };
    }
    @rows || !@input_failures
      or die "all supplied result files were empty or malformed\n";
    my $report = {
        generated_at => _timestamp(),
        input_failures => \@input_failures,
        plan_counts => $plan->{counts},
        plan_total_groups => $plan->{total_groups},
        plan_total_targets => $plan->{total_targets},
        result_counts => _aggregate_results( \@rows ),
        results => \@rows,
        source_group_filter => $plan->{source_group_filter},
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
    my ( $config, $opt ) = @_;
    $opt ||= {};
    my $source_auth = _load_source_auth();
    my @inventory;
    my @missing_source_groups;
    my @excluded_source_groups;
    my $authoritative_projects = _config_authoritative_projects_by_target_full_path($config);
    my $has_authoritative_projects = scalar keys %{$authoritative_projects};
    my @units = @{ _discover_inventory_units($config) };
    my $total_units = scalar @units;
    my $processed_units = 0;

    for (
        my $unit_index = $opt->{unit_start} || 0;
        $unit_index < $total_units;
        $unit_index += ( $opt->{unit_stride} || 1 )
      )
    {
        last if ( $opt->{unit_limit} || 0 ) > 0 && $processed_units >= $opt->{unit_limit};
        my $unit = $units[$unit_index];
        next unless ref($unit) eq "HASH";
        if ( $unit->{type} eq "namespace" || $unit->{type} eq "namespace_source_group_path" ) {
            my $namespace = $config->{namespaces}->[ $unit->{index} ];
            if ( $unit->{type} eq "namespace_source_group_path" ) {
                my $source_group_paths = $namespace->{source_group_paths};
                ref($source_group_paths) eq "ARRAY"
                  or die "namespace_source_group_path discovery unit requires source_group_paths\n";
                my $source_group_path = $source_group_paths->[ $unit->{source_group_path_index} ];
                defined $source_group_path
                  or die "namespace_source_group_path discovery unit index is out of range\n";
                $namespace = {
                    %{$namespace},
                    source_group_paths => [$source_group_path],
                };
            }
            my $policy = _merge_policy( $config->{defaults}, $namespace, {} );
            my $namespace_inventory =
              _discover_namespace_inventory( $namespace, $policy, $source_auth, $config );
            my $namespace_buckets =
                ref($namespace_inventory) eq "HASH"
              ? $namespace_inventory->{inventory}
              : $namespace_inventory;
            if ( ref($namespace_inventory) eq "HASH" ) {
                push @missing_source_groups,
                  grep { ref($_) eq "HASH" } @{ $namespace_inventory->{missing_source_groups} || [] };
                push @excluded_source_groups,
                  grep { ref($_) eq "HASH" } @{ $namespace_inventory->{excluded_source_groups} || [] };
            }
            if ( !$has_authoritative_projects ) {
                push @inventory, @{$namespace_buckets};
                $processed_units++;
                next;
            }
            for my $bucket ( @{$namespace_buckets} ) {
                my @projects;
                for my $source_project ( @{ $bucket->{projects} || [] } ) {
                    my $source_full_path = _required_string( $source_project->{path_with_namespace}, "path_with_namespace" );
                    my $target_paths = _resolve_namespace_project_target_paths(
                        $bucket->{namespace},
                        $bucket->{group_path},
                        $source_full_path,
                    );
                    my $authoritative = $authoritative_projects->{ $target_paths->{target_full_path} };
                    next if $authoritative;
                    push @projects, $source_project;
                }
                next unless @projects;
                push @inventory, { %{$bucket}, projects => \@projects };
            }
        }
        elsif ( $unit->{type} eq "project" ) {
            my $project = $config->{projects}->[ $unit->{index} ];
            my $policy = _merge_policy( $config->{defaults}, {}, $project );
            push @inventory, @{
                _discover_project_inventory(
                    $project,
                    $policy,
                    $source_auth,
                    {
                        namespace => _matching_namespace_for_explicit_project( $config, $project ),
                    },
                )
            };
        }
        else {
            die "unsupported discovery unit type: $unit->{type}\n";
        }
        $processed_units++;
    }
    return {
        discovered_at => _timestamp(),
        inventory => \@inventory,
        missing_source_groups => \@missing_source_groups,
        excluded_source_groups => \@excluded_source_groups,
    };
}

sub _discover_inventory_units {
    my ($config) = @_;
    my @units;
    for my $index ( 0 .. $#{ $config->{namespaces} || [] } ) {
        my $namespace = $config->{namespaces}->[$index];
        my $source_group_paths = ref($namespace) eq "HASH" ? $namespace->{source_group_paths} : undef;
        if ( ref($source_group_paths) eq "ARRAY" && @{$source_group_paths} ) {
            for my $source_group_path_index ( 0 .. $#{$source_group_paths} ) {
                push @units,
                  {
                    index => $index,
                    source_group_path_index => $source_group_path_index,
                    type => "namespace_source_group_path",
                  };
            }
            next;
        }
        push @units, { index => $index, type => "namespace" };
    }
    for my $index ( 0 .. $#{ $config->{projects} || [] } ) {
        push @units, { index => $index, type => "project" };
    }
    return \@units;
}

sub _matching_namespace_for_explicit_project {
    my ( $config, $project ) = @_;
    return undef unless ref($config) eq "HASH";
    return undef unless ref($project) eq "HASH";
    my $target_paths = _resolve_explicit_project_target_paths($project);
    my $target_full_path = $target_paths->{target_full_path};
    my @matches;
    for my $namespace ( @{ $config->{namespaces} || [] } ) {
        next unless ref($namespace) eq "HASH";
        my $root = _join_path(
            _required_relative_namespace_path(
                $namespace->{target_owner_path},
                "target_owner_path",
            ),
            _required_relative_namespace_path(
                $namespace->{target_namespace_path},
                "target_namespace_path",
            ),
        );
        next unless index( $target_full_path, $root . "/" ) == 0;
        push @matches, [ length($root), $namespace ];
    }
    return undef unless @matches;
    @matches = sort { $b->[0] <=> $a->[0] } @matches;
    if ( @matches > 1 && $matches[0]->[0] == $matches[1]->[0] ) {
        die "authoritative projects.yml target maps to multiple namespace entries: $target_full_path\n";
    }
    return $matches[0]->[1];
}

sub _merge_discover_payloads {
    my ($payloads) = @_;
    ref($payloads) eq "ARRAY" or die "discover payloads must be a list\n";
    my @inventory;
    my @missing_source_groups;
    my @excluded_source_groups;
    for my $payload ( @{$payloads} ) {
        ref($payload) eq "HASH" or die "discover payload must be an object\n";
        push @inventory,
          grep { ref($_) eq "HASH" } @{ $payload->{inventory} || [] };
        push @missing_source_groups,
          grep { ref($_) eq "HASH" } @{ $payload->{missing_source_groups} || [] };
        push @excluded_source_groups,
          grep { ref($_) eq "HASH" } @{ $payload->{excluded_source_groups} || [] };
    }
    return {
        discovered_at => _timestamp(),
        inventory => \@inventory,
        missing_source_groups => \@missing_source_groups,
        excluded_source_groups => \@excluded_source_groups,
    };
}

sub _discover_namespace_inventory {
    my ( $namespace, $policy, $source_auth, $config ) = @_;
    my $source = _parse_source_url(
        $namespace->{source_group_url},
        sub {
            my ($base_url) = @_;
            return _is_gitlab_instance_root( $base_url, $policy );
        },
    );
    my $source_group_paths = $namespace->{source_group_paths};
    if ( ref($source_group_paths) eq "ARRAY" && @{$source_group_paths} && $source->{kind} ne "gitlab_instance_root" ) {
        die "groups.jsonl is only supported for GitLab instance-root source_group_url values\n";
    }
    my @excluded_source_groups;

    if ( $source->{kind} eq "gitlab_group" ) {
        my $exclude_reason = _source_group_exclusion_reason( $config, $source->{root_path} );
        if ($exclude_reason) {
            warn "source group excluded by config: $source->{root_path}; skipping\n";
            push @excluded_source_groups,
              _source_group_notice_entry( $namespace, $source->{base_url}, $source->{root_path}, $exclude_reason );
            return {
                inventory => [],
                missing_source_groups => [],
                excluded_source_groups => \@excluded_source_groups,
            };
        }
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
        my $groups;
        my @missing_source_groups;
        if ( ref($source_group_paths) eq "ARRAY" && @{$source_group_paths} ) {
            my @selected_groups;
            for my $path ( @{$source_group_paths} ) {
                my $exclude_reason = _source_group_exclusion_reason( $config, $path );
                if ($exclude_reason) {
                    warn "configured source group path excluded by config: $path; skipping\n";
                    push @excluded_source_groups,
                      _source_group_notice_entry( $namespace, $source->{base_url}, $path, $exclude_reason );
                    next;
                }
                my $group = _get_group( $source_client, $path, _gitlab_read_request_opt($policy) );
                if ( !$group ) {
                    warn "configured source group path not found at GitLab instance root: $path; skipping\n";
                    push @missing_source_groups,
                      _source_group_notice_entry( $namespace, $source->{base_url}, $path );
                    next;
                }
                push @selected_groups, $group;
            }
            $groups = \@selected_groups;
        }
        else {
            $groups = _list_gitlab_top_level_groups( $source_client, $policy );
        }
        my @selected_groups;
        for my $group ( @{$groups} ) {
            next unless ref($group) eq "HASH";
            my $group_path = _required_relative_namespace_path(
                $group->{full_path} || $group->{path},
                "gitlab top-level group path",
            );
            my $exclude_reason = _source_group_exclusion_reason( $config, $group_path );
            if ($exclude_reason) {
                warn "source group excluded by config: $group_path; skipping\n";
                push @excluded_source_groups,
                  _source_group_notice_entry( $namespace, $source->{base_url}, $group_path, $exclude_reason );
                next;
            }
            push @selected_groups, $group;
        }
        $groups = \@selected_groups;
        my @inventory;
        for my $group ( @{$groups} ) {
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
        return {
            inventory => \@inventory,
            missing_source_groups => \@missing_source_groups,
            excluded_source_groups => \@excluded_source_groups,
        };
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
    my @missing_source_groups;
    for my $item ( @{ $inventory->{missing_source_groups} || [] } ) {
        next unless ref($item) eq "HASH";
        push @missing_source_groups,
          {
            base_url => $item->{base_url},
            namespace_name => $item->{namespace_name},
            source_group_path => $item->{source_group_path},
            target_namespace_path => $item->{target_namespace_path},
          };
    }
    my @excluded_source_groups;
    for my $item ( @{ $inventory->{excluded_source_groups} || [] } ) {
        next unless ref($item) eq "HASH";
        push @excluded_source_groups,
          {
            base_url => $item->{base_url},
            namespace_name => $item->{namespace_name},
            reason => $item->{reason},
            source_group_path => $item->{source_group_path},
            target_namespace_path => $item->{target_namespace_path},
          };
    }
    return {
        discovered_at => $inventory->{discovered_at},
        inventory => \@normalized,
        missing_source_groups => \@missing_source_groups,
        excluded_source_groups => \@excluded_source_groups,
    };
}

sub _build_plan {
    my ( $config, $inventory, $batch_size, $opt ) = @_;
    $opt ||= {};
    _assert_inventory_honors_source_group_filter( $config, $inventory );
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
                  : _merge_policy( $config->{defaults}, {}, $project_entry );
                my $skip_reason = _config_exclusion_reason( $config, $target_paths );
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
                    requested_target_full_path => $target_paths->{requested_target_full_path},
                    requested_target_relative_project_path => $target_paths->{requested_target_relative_project_path},
                    target_full_path => $target_paths->{target_full_path},
                    target_project_name => $target_paths->{target_project_name},
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
            my $skip_reason = _config_exclusion_reason( $config, $target_paths );
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
                requested_target_full_path => $target_paths->{requested_target_full_path},
                requested_target_relative_project_path => $target_paths->{requested_target_relative_project_path},
                target_full_path => $target_paths->{target_full_path},
                target_project_name => $target_paths->{target_project_name},
                target_relative_project_path => $target_paths->{target_relative_project_path},
                target_namespace_path => $target_paths->{target_namespace_path},
              };
        }
    }

    my %group_target_counts;
    for my $entry (@plan) {
        my $group_key = _plan_group_priority_key($entry);
        $group_target_counts{$group_key}++;
    }
    @plan = sort {
        $group_target_counts{ _plan_group_priority_key($a) }
          <=>
          $group_target_counts{ _plan_group_priority_key($b) }
          || _plan_group_priority_key($a) cmp _plan_group_priority_key($b)
          || ( $a->{target_namespace_path} || q{} ) cmp ( $b->{target_namespace_path} || q{} )
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
        source_group_filter => _source_group_filter_summary( $config, $inventory, \@plan, $total_groups ),
        total_batches => scalar @{$batches},
        total_groups => $total_groups,
        total_targets => scalar @plan,
    };
}

sub _configured_source_group_paths {
    my ($config) = @_;
    my @paths;
    for my $namespace ( @{ $config->{namespaces} || [] } ) {
        next unless ref($namespace) eq "HASH";
        my $source_group_paths = $namespace->{source_group_paths};
        next unless ref($source_group_paths) eq "ARRAY";
        push @paths, grep { defined $_ && !ref($_) && length $_ } @{$source_group_paths};
    }
    return \@paths;
}

sub _source_group_filter_lookup {
    my ($config) = @_;
    my %allowed = map { ( $_ => 1 ) } @{ _configured_source_group_paths($config) };
    return \%allowed;
}

sub _assert_inventory_honors_source_group_filter {
    my ( $config, $inventory ) = @_;
    my $allowed = _source_group_filter_lookup($config);
    return unless %{$allowed};

    for my $bucket ( @{ $inventory->{inventory} || [] } ) {
        next unless ref($bucket) eq "HASH";
        next if ref( $bucket->{project_entry} ) eq "HASH";
        my $source_group_path = _required_relative_namespace_path(
            $bucket->{group_path},
            "discovered source group path",
        );
        exists $allowed->{$source_group_path}
          or die "discovery returned source group outside groups.jsonl allowlist: $source_group_path\n";
        my $exclude_reason = _source_group_exclusion_reason( $config, $source_group_path );
        defined $exclude_reason
          and die "discovery returned source group excluded by config: $source_group_path\n";
    }
}

sub _source_group_filter_summary {
    my ( $config, $inventory, $plan, $target_namespace_count ) = @_;
    my @configured_source_groups = @{ _configured_source_group_paths($config) };
    my %inventory_source_groups;
    my %planned_source_groups;
    my %planned_targets_by_source_group;

    for my $bucket ( @{ $inventory->{inventory} || [] } ) {
        next unless ref($bucket) eq "HASH";
        next if ref( $bucket->{project_entry} ) eq "HASH";
        my $path = $bucket->{group_path};
        next unless defined $path && !ref($path) && length $path;
        $inventory_source_groups{$path}++;
    }
    for my $entry ( @{$plan || []} ) {
        next unless ref($entry) eq "HASH";
        my $path = $entry->{source_group_path};
        next unless defined $path && !ref($path) && length $path;
        $planned_source_groups{$path} = 1;
        $planned_targets_by_source_group{$path}++;
    }

    my @top_source_groups = sort {
        $planned_targets_by_source_group{$b} <=> $planned_targets_by_source_group{$a}
          || $a cmp $b
    } keys %planned_targets_by_source_group;
    splice @top_source_groups, 10 if @top_source_groups > 10;

    my $mode =
        @configured_source_groups     ? "groups.jsonl"
      : @{ $config->{namespaces} || [] } ? "namespace"
      :                                  "projects-only";

    return {
        configured_source_groups => scalar @configured_source_groups,
        discovered_source_groups => scalar keys %inventory_source_groups,
        excluded_source_groups => scalar( grep { ref($_) eq "HASH" } @{ $inventory->{excluded_source_groups} || [] } ),
        missing_source_groups => scalar( grep { ref($_) eq "HASH" } @{ $inventory->{missing_source_groups} || [] } ),
        mode => $mode,
        planned_source_groups => scalar keys %planned_source_groups,
        target_project_namespaces => $target_namespace_count,
        top_source_groups_by_targets => [
            map {
                {
                    planned_targets => $planned_targets_by_source_group{$_},
                    source_group_path => $_,
                }
            } @top_source_groups
        ],
    };
}

sub _mirror_entry {
    my ( $target_client, $source_auth, $entry, $prepared_override ) = @_;
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

    if ( $entry->{source_empty_repo} && ref($prepared_override) eq "HASH" ) {
        my $resolved_target_full_path =
          $prepared_override->{resolved_target_full_path}
          || $entry->{target_full_path};
        my $requested_target_full_path =
             $prepared_override->{requested_target_full_path}
          || $entry->{requested_target_full_path}
          || (
            $resolved_target_full_path ne $entry->{target_full_path}
            ? $entry->{target_full_path}
            : undef
          );
        my $prepared_action =
            $prepared_override->{created} ? "create_project"
          : $prepared_override->{updated} ? "update_project"
          : "mirror_only";
        return {
            target_full_path => $resolved_target_full_path,
            (
                defined $requested_target_full_path
                ? ( requested_target_full_path => $requested_target_full_path )
                : ()
            ),
            planned_action => $entry->{action},
            prepared_action => $prepared_action,
            status => $prepared_override->{created} ? "created_empty" : "updated_empty",
            prepared => $prepared_override,
            verify => {
                skipped => JSON::PP::true,
                reason => "Skipped target verification for empty source repository.",
                target_full_path => $resolved_target_full_path,
            },
        };
    }

    my $requested_target_full_path = $entry->{requested_target_full_path};
    my $entry_source_auth = _resolve_source_auth_for_entry( $source_auth, $entry );
    my $source_url = _maybe_auth_url( $entry->{source_http_url}, $entry_source_auth->{username}, $entry_source_auth->{token} );
    my $chosen_source_url = $source_url;
    my $available = eval {
        _discover_remote_refs_from_urls(
            [ $source_url, _fallback_clone_url($source_url) ],
            $entry->{policy},
            \$chosen_source_url,
        );
    };
    if ( !$available ) {
        my $source_error = _trim_error($@);
        if ( _git_output_reports_missing_source_credentials($source_error) ) {
            return {
                target_full_path => $entry->{target_full_path},
                (
                    defined $requested_target_full_path
                    ? ( requested_target_full_path => $requested_target_full_path )
                    : ()
                ),
                planned_action => $entry->{action},
                status => "skipped",
                reason => "Source repository refused anonymous public Git reads.",
                error => $source_error,
                failure_context => "source-ls-remote",
            };
        }
        die $source_error =~ /\n\z/ ? $source_error : $source_error . "\n";
    }
    my $default_branch = $entry->{source_default_branch} || $available->{default_branch} || "";
    my $selected = resolve_selected_refs( $default_branch, $entry->{policy}, $available );
    @{ $selected->{branches} } || $entry->{source_empty_repo}
      or die "no source branches resolved for $entry->{source_full_path}\n";

    my $prepared_from_override = ref($prepared_override) eq "HASH";
    my $target_remote_refs =
      $prepared_from_override
      ? undef
      : _discover_target_remote_refs_if_exists(
            $target_client,
            $entry->{target_full_path},
            $entry->{policy},
        );

    if ( $entry->{source_empty_repo} && $target_remote_refs ) {
        return {
            target_full_path => $entry->{target_full_path},
            (
                defined $requested_target_full_path
                ? ( requested_target_full_path => $requested_target_full_path )
                : ()
            ),
            planned_action => $entry->{action},
            prepared_action => "mirror_only",
            status => "skipped",
            reason => "Source repository is empty and the target repository already exists.",
            verify => {
                skipped => JSON::PP::true,
                reason => "Skipped target verification for empty source repository.",
                target_full_path => $entry->{target_full_path},
            },
        };
    }

    if (
        $target_remote_refs
        && _selected_refs_already_synced(
            $selected,
            $available,
            $target_remote_refs,
            $default_branch,
            $target_client->{sync_branch},
            $entry->{policy},
        )
      )
    {
        return {
            target_full_path => $entry->{target_full_path},
            (
                defined $requested_target_full_path
                ? ( requested_target_full_path => $requested_target_full_path )
                : ()
            ),
            planned_action => $entry->{action},
            prepared_action => "mirror_only",
            selected_refs => $selected,
            status => "skipped",
            reason => "Selected source refs already match the target repository.",
            verify => {
                skipped => JSON::PP::true,
                reason => "Skipped target verification because selected refs already match the target repository.",
                target_full_path => $entry->{target_full_path},
            },
        };
    }

    my $refs_to_sync =
      $target_remote_refs
      ? _selected_refs_requiring_sync(
            $selected,
            $available,
            $target_remote_refs,
            $default_branch,
            $target_client->{sync_branch},
            $entry->{policy},
        )
      : $selected;

    my $prepared =
      $prepared_from_override
      ? $prepared_override
      : $target_remote_refs
      ? {
            created => JSON::PP::false,
            requested_target_full_path => $entry->{requested_target_full_path},
            resolved_target_full_path => $entry->{target_full_path},
            resolved_target_namespace_path => $entry->{target_namespace_path},
            updated => JSON::PP::false,
        }
      : _ensure_target_project( $target_client, $entry );
    my $resolved_target_full_path =
      $prepared->{resolved_target_full_path}
      || $entry->{target_full_path};
    $requested_target_full_path =
         $prepared->{requested_target_full_path}
      || $requested_target_full_path
      || (
        $resolved_target_full_path ne $entry->{target_full_path}
        ? $entry->{target_full_path}
        : undef
      );
    my $prepared_action =
        $prepared->{created} ? "create_project"
      : $prepared->{updated} ? "update_project"
      : "mirror_only";
    if ( $entry->{source_empty_repo} ) {
        return {
            target_full_path => $resolved_target_full_path,
            (
                defined $requested_target_full_path
                ? ( requested_target_full_path => $requested_target_full_path )
                : ()
            ),
            planned_action => $entry->{action},
            prepared_action => $prepared_action,
            status => $prepared->{created} ? "created_empty" : "updated_empty",
            prepared => $prepared,
            verify => {
                skipped => JSON::PP::true,
                reason => "Skipped target verification for empty source repository.",
                target_full_path => $resolved_target_full_path,
            },
        };
    }

    my $workdir = tempdir( CLEANUP => 1 );
    my $repo_dir = File::Spec->catdir( $workdir, "repo" );
    my $init_result = _run_command( [ "git", "init", $repo_dir ], { timeout => 120 } );
    $init_result->{status} == 0 or die "git init failed: $init_result->{output}\n";

    my $target_url = _maybe_auth_url(
        _project_git_url( $target_client->{base_url}, $resolved_target_full_path ),
        $target_client->{username},
        $target_client->{token},
    );
    my $remote_result = _run_command( [ "git", "-C", $repo_dir, "remote", "add", "source", $chosen_source_url ], { timeout => 60 } );
    $remote_result->{status} == 0 or die "git remote add source failed: $remote_result->{output}\n";
    $remote_result = _run_command( [ "git", "-C", $repo_dir, "remote", "add", "target", $target_url ], { timeout => 60 } );
    $remote_result->{status} == 0 or die "git remote add target failed: $remote_result->{output}\n";

    _fetch_selected_refs( $repo_dir, $refs_to_sync, $entry->{policy} );
    _checkout_selected_ref( $repo_dir, $refs_to_sync );

    my $size_before = analyze_selected_refs( $repo_dir, $refs_to_sync, $entry->{policy}->{max_blob_bytes} );
    if ( $size_before->{total_bytes} > $entry->{policy}->{size_limit_bytes} ) {
        return {
            target_full_path => $resolved_target_full_path,
            (
                defined $requested_target_full_path
                ? ( requested_target_full_path => $requested_target_full_path )
                : ()
            ),
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
            _rewrite_large_blobs_to_lfs( $repo_dir, $refs_to_sync, $entry->{policy}->{max_blob_bytes}, $entry->{policy} );
            1;
        };
        if ($ok) {
            $size_after = analyze_selected_refs( $repo_dir, $refs_to_sync, $entry->{policy}->{max_blob_bytes} );
        }
        else {
            $lfs_rewrite_error = _trim_error($@);
        }
    }
    if ( @{ $size_after->{oversized_blobs} } || $lfs_rewrite_error ) {
        return {
            target_full_path => $resolved_target_full_path,
            (
                defined $requested_target_full_path
                ? ( requested_target_full_path => $requested_target_full_path )
                : ()
            ),
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
    my $ensure_lfs_ready = sub {
        if ( !$prepared->{project_id} ) {
            my $ensured = _ensure_target_project( $target_client, $entry );
            %{$prepared} = ( %{$prepared}, %{$ensured} );
        }
        _ensure_target_lfs_enabled( $target_client, $prepared->{project_id} );
        return 1;
    };
    my $sync_lfs_objects = sub {
        return if $prepared->{lfs_synced};
        $ensure_lfs_ready->();
        _sync_lfs_objects( $repo_dir, $refs_to_sync, $entry->{policy} );
        $prepared->{lfs_synced} = JSON::PP::true;
        return 1;
    };
    my $resync_lfs_objects = sub {
        $ensure_lfs_ready->();
        _run_git_lfs_push_all( $repo_dir, $entry->{policy} );
        $prepared->{lfs_synced} = JSON::PP::true;
        return 1;
    };
    if ($needs_lfs) {
        $sync_lfs_objects->();
    }

    my $push_ok = eval {
        _push_selected_refs(
            $repo_dir,
            $refs_to_sync,
            $entry->{policy},
            $default_branch,
            $target_client->{sync_branch},
            {
                on_missing_lfs => $resync_lfs_objects,
            },
        );
        1;
    };
    if ( !$push_ok ) {
        my $push_error = _trim_error($@);
        if ( _git_output_reports_lfs_storage_quota_exceeded($push_error) ) {
            return {
                target_full_path => $resolved_target_full_path,
                (
                    defined $requested_target_full_path
                    ? ( requested_target_full_path => $requested_target_full_path )
                    : ()
                ),
                planned_action => $entry->{action},
                prepared_action => $prepared_action,
                prepared => $prepared,
                selected_refs => $selected,
                size => $size_after,
                needs_lfs => $needs_lfs ? JSON::PP::true : JSON::PP::false,
                lfs_rewrite_attempted => $lfs_rewrite_attempted,
                status => "skipped",
                reason => "Target GitLab project rejected the LFS upload because its storage quota is exhausted.",
                error => $push_error,
            };
        }
        die $push_error =~ /\n\z/ ? $push_error : $push_error . "\n";
    }
    if ( _prepared_requires_finalize( $prepared, $entry ) ) {
        if ( !$prepared->{project_id} ) {
            my $ensured = _ensure_target_project( $target_client, $entry );
            %{$prepared} = ( %{$prepared}, %{$ensured} );
        }
        _finalize_target_project( $target_client, $prepared->{project_id}, $default_branch, $entry );
    }
    my $verified = {
        skipped => JSON::PP::true,
        reason => "Skipped target verification to avoid redundant target API reads.",
        target_full_path => $resolved_target_full_path,
    };

    return {
        target_full_path => $resolved_target_full_path,
        (
            defined $requested_target_full_path
            ? ( requested_target_full_path => $requested_target_full_path )
            : ()
        ),
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
    my ( $target_client, $entry, $selected, $source_default_branch, $target_sync_branch ) = @_;
    $target_sync_branch = _required_git_ref_name( $target_sync_branch, "target sync branch" );
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
              ? $target_sync_branch
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
    my $text = join(
        "",
        "## Group Mirror Plan\n\n",
        "- generated_at: $plan->{generated_at}\n",
        _render_source_group_filter_summary( $plan->{source_group_filter} ),
        "- planned_targets: $plan->{total_targets}\n",
        "- planned_actions: sync=", ( $plan->{counts}->{sync} || 0 ),
        " skip=", ( $plan->{counts}->{skip} || 0 ),
        " fail=", ( $plan->{counts}->{fail} || 0 ), "\n",
        "- batches: total=", ( $plan->{total_batches} || 0 ),
        " batch_size=", ( $plan->{batch_size} || 0 ), "\n",
    );
    $text .= _render_top_source_groups_summary( $plan->{source_group_filter} );
    my @missing_source_groups =
      grep { ref($_) eq "HASH" } @{ $plan->{missing_source_groups} || [] };
    if (@missing_source_groups) {
        $text .= "\n### Missing Source Groups\n\n";
        for my $item (@missing_source_groups) {
            my $label = $item->{namespace_name} ? "$item->{namespace_name}: " : q{};
            my $path = $item->{source_group_path} || "<unknown>";
            my $base_url = $item->{base_url} || "<unknown>";
            my $target_path = $item->{target_namespace_path} || $path;
            $text .= "- `$label$path` from `$base_url` skipped; target path `$target_path` will not be mirrored this run.\n";
        }
    }
    my @excluded_source_groups =
      grep { ref($_) eq "HASH" } @{ $plan->{excluded_source_groups} || [] };
    if (@excluded_source_groups) {
        $text .= "\n### Excluded Source Groups\n\n";
        for my $item (@excluded_source_groups) {
            my $label = $item->{namespace_name} ? "$item->{namespace_name}: " : q{};
            my $path = $item->{source_group_path} || "<unknown>";
            my $base_url = $item->{base_url} || "<unknown>";
            my $target_path = $item->{target_namespace_path} || $path;
            my $reason = $item->{reason} || "Excluded source group by config";
            $text .= "- `$label$path` from `$base_url` skipped by config; target path `$target_path` will not be mirrored this run. Reason: $reason\n";
        }
    }
    return $text;
}

sub _render_source_group_filter_summary {
    my ($filter) = @_;
    return q{} unless ref($filter) eq "HASH";
    my $text = join(
        "",
        "- source_filter: ", ( $filter->{mode} || "unknown" ), "\n",
        "- configured_source_groups: ", ( $filter->{configured_source_groups} || 0 ), "\n",
        "- discovered_source_groups: ", ( $filter->{discovered_source_groups} || 0 ), "\n",
        "- planned_source_groups: ", ( $filter->{planned_source_groups} || 0 ), "\n",
        "- target_project_namespaces: ", ( $filter->{target_project_namespaces} || 0 ), "\n",
        "- missing_source_groups: ", ( $filter->{missing_source_groups} || 0 ), "\n",
        "- excluded_source_groups: ", ( $filter->{excluded_source_groups} || 0 ), "\n",
    );
    return $text;
}

sub _render_top_source_groups_summary {
    my ($filter) = @_;
    return q{} unless ref($filter) eq "HASH";
    my @top_source_groups =
      grep { ref($_) eq "HASH" } @{ $filter->{top_source_groups_by_targets} || [] };
    return q{} unless @top_source_groups;
    my $text = "\n### Largest Source Groups By Planned Targets\n\n";
    for my $item (@top_source_groups) {
        my $path = $item->{source_group_path} || "<unknown>";
        my $count = $item->{planned_targets} || 0;
        $text .= "- `$path`: $count\n";
    }
    return $text;
}

sub _render_report_summary {
    my ($report) = @_;
    my $counts = $report->{result_counts} || {};
    my @input_failures = grep { ref($_) eq "HASH" } @{ $report->{input_failures} || [] };
    my @failed = grep { ( $_->{status} || "" ) eq "failed" } @{ $report->{results} || [] };
    my $skip_breakdown = _summary_skip_breakdown( $report->{results} || [] );
    my @other_skipped = @{ $skip_breakdown->{other_skipped} || [] };

    my $text = join(
        "",
        "## Group Mirror Overview\n\n",
        "- generated_at: $report->{generated_at}\n",
        _render_source_group_filter_summary( $report->{source_group_filter} ),
        "- planned_targets: ", ( $report->{plan_total_targets} || 0 ), "\n",
        "- results: mirrored=", ( $counts->{mirrored} || 0 ),
        " created_empty=", ( $counts->{created_empty} || 0 ),
        " updated_empty=", ( $counts->{updated_empty} || 0 ), "\n",
        "- skipped: total=", ( $counts->{skipped} || 0 ),
        " archived=", ( $skip_breakdown->{archived_skipped} || 0 ),
        " refs_matched=", ( $skip_breakdown->{refs_matched_skipped} || 0 ),
        " other=", scalar @other_skipped, "\n",
        "- failed: ", ( $counts->{failed} || 0 ),
        " result_file_errors=", scalar @input_failures, "\n\n",
    );
    $text .= _render_top_source_groups_summary( $report->{source_group_filter} );
    if (@input_failures) {
        $text .= "### Result File Errors\n\n";
        for my $item (@input_failures) {
            $text .= _render_summary_item( $item, "error" );
        }
        $text .= "\n";
    }
    if (@other_skipped) {
        $text .= "### Other Skipped\n\n";
        for my $item (@other_skipped) {
            $text .= _render_summary_item( $item, "reason" );
        }
        $text .= "\n";
    }
    if (@failed) {
        $text .= "### Failed\n\n";
        for my $item (@failed) {
            $text .= _render_summary_item( $item, "error" );
        }
        $text .= "\n";
    }
    return $text;
}

sub _summary_skip_breakdown {
    my ($results) = @_;
    my $archived_reason = "Archived source repository is excluded from mirroring.";
    my $refs_matched_reason = "Selected source refs already match the target repository.";
    my $archived_skipped = 0;
    my $refs_matched_skipped = 0;
    my @other_skipped;

    for my $item ( @{$results || []} ) {
        next unless ref($item) eq "HASH";
        next unless ( $item->{status} || q{} ) eq "skipped";
        my $reason = $item->{reason} || $item->{error} || "skipped";
        if ( $reason eq $archived_reason ) {
            $archived_skipped++;
            next;
        }
        if ( $reason eq $refs_matched_reason ) {
            $refs_matched_skipped++;
            next;
        }
        push @other_skipped, $item;
    }

    return {
        archived_skipped => $archived_skipped,
        refs_matched_skipped => $refs_matched_skipped,
        other_skipped => \@other_skipped,
    };
}

sub _render_summary_item {
    my ( $item, $field ) = @_;
    return q{} unless ref($item) eq "HASH";
    my $target = $item->{target_full_path} || $item->{file} || "<unknown>";
    my $detail =
         ( defined $field ? $item->{$field} : undef )
      || $item->{error}
      || $item->{reason}
      || "unknown";
    $detail = _trim_error($detail);
    return "- `$target`: $detail\n" if $detail !~ /\n/;
    return join(
        "",
        "- `$target`:\n\n",
        "```text\n",
        $detail, "\n",
        "```\n",
    );
}

sub _normalize_defaults_payload {
    my ( $payload, $label ) = @_;
    ref($payload) eq "HASH" or die "$label.defaults must be an object\n";
    _reject_visibility_key( $payload, "$label.defaults" );
    _reject_project_only_key( $payload, "$label.defaults", "mirror_pristine_tar" );
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.defaults.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.defaults.additional_tags" ),
        allow_blob_rewrite => _bool_or_default( $payload->{allow_blob_rewrite}, 1 ),
        batch_size => _defaulted_positive_int( $payload->{batch_size}, $DEFAULTS{batch_size}, "$label.defaults.batch_size" ),
        force_lfs => _bool_or_default( $payload->{force_lfs}, 0 ),
        git_timeout_seconds => _defaulted_positive_int( $payload->{git_timeout_seconds}, $DEFAULTS{git_timeout_seconds}, "$label.defaults.git_timeout_seconds" ),
        max_blob_bytes => _defaulted_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.defaults.max_blob_bytes" ),
        max_parallel => _defaulted_bounded_positive_int( $payload->{max_parallel}, $DEFAULTS{max_parallel}, $DEFAULTS{max_parallel}, "$label.defaults.max_parallel" ),
        gitlab_source_include_subgroups => _bool_or_default( $payload->{gitlab_source_include_subgroups}, 0 ),
        read_retry_attempts => _defaulted_positive_int( $payload->{read_retry_attempts}, $GITLAB_READ_DEFAULTS{retry_attempts}, "$label.defaults.read_retry_attempts" ),
        read_retry_backoff_seconds => _defaulted_positive_int( $payload->{read_retry_backoff_seconds}, $GITLAB_READ_DEFAULTS{retry_backoff_seconds}, "$label.defaults.read_retry_backoff_seconds" ),
        retry_attempts => _defaulted_positive_int( $payload->{retry_attempts}, $DEFAULTS{retry_attempts}, "$label.defaults.retry_attempts" ),
        retry_backoff_seconds => _defaulted_positive_int( $payload->{retry_backoff_seconds}, $DEFAULTS{retry_backoff_seconds}, "$label.defaults.retry_backoff_seconds" ),
        size_limit_bytes => _defaulted_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.defaults.size_limit_bytes" ),
    };
}

sub _normalize_namespace {
    my ( $payload, $label ) = @_;
    ref($payload) eq "HASH" or die "$label must be an object\n";
    _reject_visibility_key( $payload, $label );
    _reject_project_only_key( $payload, $label, "mirror_pristine_tar" );
    return {
        additional_branches => _normalize_ref_specs( $payload->{additional_branches}, "$label.additional_branches" ),
        additional_tags => _normalize_ref_specs( $payload->{additional_tags}, "$label.additional_tags" ),
        allow_blob_rewrite => _optional_bool( $payload->{allow_blob_rewrite} ),
        force_lfs => _optional_bool( $payload->{force_lfs} ),
        git_timeout_seconds => $payload->{git_timeout_seconds},
        gitlab_source_include_subgroups => _optional_bool( $payload->{gitlab_source_include_subgroups} ),
        name => _required_string( $payload->{name}, "$label.name" ),
        read_retry_attempts => _optional_positive_int( $payload->{read_retry_attempts}, "$label.read_retry_attempts" ),
        read_retry_backoff_seconds => _optional_positive_int( $payload->{read_retry_backoff_seconds}, "$label.read_retry_backoff_seconds" ),
        retry_attempts => _optional_positive_int( $payload->{retry_attempts}, "$label.retry_attempts" ),
        retry_backoff_seconds => _optional_positive_int( $payload->{retry_backoff_seconds}, "$label.retry_backoff_seconds" ),
        size_limit_bytes => _optional_bounded_positive_int( $payload->{size_limit_bytes}, $DEFAULTS{size_limit_bytes}, "$label.size_limit_bytes" ),
        max_blob_bytes => _optional_bounded_positive_int( $payload->{max_blob_bytes}, $DEFAULTS{max_blob_bytes}, "$label.max_blob_bytes" ),
        source_group_url => _required_https_url( $payload->{source_group_url}, "$label.source_group_url" ),
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

sub _normalize_source_group_path {
    my ( $payload, $label ) = @_;
    if ( !ref($payload) ) {
        return _required_relative_namespace_path( $payload, $label );
    }
    ref($payload) eq "HASH" or die "$label must be a string or object\n";
    return _required_relative_namespace_path(
        $payload->{source_group_path},
        "$label.source_group_path",
    );
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
    if ( ref($override) eq "HASH" && exists $override->{mirror_pristine_tar} && defined $override->{mirror_pristine_tar} ) {
        $policy->{mirror_pristine_tar} = $override->{mirror_pristine_tar};
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
    my @target_branches_to_protect;
    my %seen_target_branches;
    for my $spec ( @{ $override->{target_branches_protect} || [] } ) {
        next unless ref($spec) eq "HASH";
        my $name = _required_string( $spec->{name}, "target_branches_protect.name" );
        next if $seen_target_branches{$name}++;
        push @target_branches_to_protect, { name => $name };
    }
    for my $spec ( @{ $override->{additional_branches} || [] } ) {
        next unless ref($spec) eq "HASH";
        my $name = _required_string( $spec->{name}, "additional_branches.name" );
        next if $seen_target_branches{$name}++;
        push @target_branches_to_protect, { name => $name };
    }
    if ( $policy->{mirror_pristine_tar} && !$seen_target_branches{"pristine-tar"}++ ) {
        push @target_branches_to_protect, { name => "pristine-tar" };
    }
    $policy->{target_branches_protect} = \@target_branches_to_protect;
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
    my $token = _required_env_file($token_secret_name);
    my $client = _make_gitlab_client(
        _required_https_url( _required_env_file("GL_BASE_URL"), "GL_BASE_URL" ),
        $TARGET_GIT_HTTPS_USERNAME,
        $token,
    );
    $client->{read_username} = $TARGET_GIT_HTTPS_USERNAME;
    $client->{read_token} = $token;
    $client->{sync_branch} =
      _required_git_ref_name(
        _required_env_file("GIT_BRANCH_GLAB_FORKS"),
        "GIT_BRANCH_GLAB_FORKS",
      );
    return $client;
}

sub _resolve_target_root_group_path {
    my ($namespace) = @_;
    return _gitlab_safe_group_path(
        _resolve_requested_target_root_group_path($namespace)
    );
}

sub _resolve_requested_target_root_group_path {
    my ($namespace) = @_;
    return _required_relative_namespace_path(
        $namespace->{target_owner_path},
        "target_owner_path",
    );
}

sub _load_source_auth {
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

sub _configure_target_namespace_state_cache_for_entries {
    my ( $client, $entries ) = @_;
    return {} unless ref($client) eq "HASH";
    return {} unless ref($entries) eq "ARRAY";
    my $enabled = $client->{enable_namespace_state_cache};
    $enabled = {} if !$enabled || ref($enabled) ne "HASH";
    my %counts;
    for my $entry ( @{$entries} ) {
        next unless ref($entry) eq "HASH";
        next if ( $entry->{action} || q{} ) eq "skip";
        next if ( $entry->{action} || q{} ) eq "fail";
        my $namespace_path = $entry->{target_namespace_path};
        next unless defined $namespace_path && !ref($namespace_path) && length $namespace_path;
        $counts{$namespace_path}++;
    }
    for my $namespace_path ( keys %counts ) {
        next unless $counts{$namespace_path} >= $TARGET_NAMESPACE_STATE_CACHE_MIN_TARGETS;
        $enabled->{$namespace_path} = JSON::PP::true;
    }
    $client->{enable_namespace_state_cache} = $enabled;
    return $enabled;
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
    my @parts = split m{/}, _required_relative_namespace_path( $group_path, "group_path" ), -1;
    @parts or die "group_path must contain at least one segment\n";

    my $current = q{};
    my $parent_id;
    for my $part (@parts) {
        $current = length $current ? "$current/$part" : $part;
        if ( exists $cache->{$current} ) {
            $parent_id = $cache->{$current};
            next;
        }
        my $group = _get_group( $client, $current );
        if ( !$group ) {
            my %payload = (
                name => $part,
                path => $part,
                visibility => "public",
                _managed_group_settings_payload(),
            );
            $payload{parent_id} = $parent_id if defined $parent_id;
            my $create_ok = eval {
                $group = _gitlab_request( $client, "POST", "/groups", \%payload );
                1;
            };
            if ( !$create_ok ) {
                my $create_error = $@ || "unknown group creation error\n";
                if ( _is_gitlab_forbidden_error($create_error) ) {
                    if ( defined $parent_id ) {
                        die sprintf(
                            "unable to create required target group %s: target token lacks permission to create this nested subgroup; pre-create it or grant subgroup creation rights: %s",
                            $current,
                            $create_error,
                        );
                    }
                    die sprintf(
                        "unable to create required target group %s: target token lacks permission to create this top-level group; pre-create it or grant top-level group creation rights: %s",
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

sub _target_namespace_state {
    my ( $client, $group_path, $policy ) = @_;
    return undef
      unless ref($client) eq "HASH" && $client->{enable_namespace_state_cache};
    if ( ref( $client->{enable_namespace_state_cache} ) eq "HASH" ) {
        return undef unless $client->{enable_namespace_state_cache}->{$group_path};
    }
    return undef
      unless defined $group_path && !ref($group_path) && length $group_path;
    my $cache = $client->{namespace_state_cache} ||= {};
    return $cache->{$group_path} if exists $cache->{$group_path};
    my $state = _build_target_namespace_state( $client, $group_path, $policy );
    $cache->{$group_path} = $state;
    return $state;
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

sub _is_gitlab_account_blocked_error {
    my ($error) = @_;
    return 0 unless defined $error && !ref($error);
    return 1 if $error =~ /account has been blocked/i;
    return 0;
}

sub _gitlab_client_blocked_error {
    my ($client) = @_;
    return undef unless ref($client) eq "HASH";
    my $error = $client->{blocked_error};
    return undef unless defined $error && !ref($error) && length $error;
    return $error;
}

sub _mark_gitlab_client_blocked {
    my ( $client, $error ) = @_;
    return unless ref($client) eq "HASH";
    return unless defined $error && !ref($error) && length $error;
    $client->{blocked_error} ||= $error;
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

sub _clear_namespace_state_cache_tree {
    my ( $cache, $group_path ) = @_;
    return if ref($cache) ne "HASH";
    for my $path ( keys %{$cache} ) {
        next unless $path eq $group_path || index( $path, $group_path . "/" ) == 0;
        delete $cache->{$path};
    }
}

sub _blocked_target_result {
    my ( $entry, $error, $context ) = @_;
    return {
        blocked => JSON::PP::true,
        error => _trim_error( $error || "target GitLab service account is blocked\n" ),
        failure_context => $context || "target",
        planned_action => $entry->{action},
        reason => "Target GitLab service account is blocked; aborting remaining API work for this shard.",
        status => "failed",
        target_full_path => $entry->{target_full_path},
    };
}

sub _prepare_target_entry_result {
    my ( $client, $entry ) = @_;
    if ( my $blocked = _gitlab_client_blocked_error($client) ) {
        return ( undef, _blocked_target_result( $entry, $blocked, "prepare-target" ) );
    }

    my $prepared = eval { _ensure_target_project( $client, $entry ) };
    if ($@) {
        my $error = _trim_error($@);
        _mark_gitlab_client_blocked( $client, $error )
          if _is_gitlab_account_blocked_error($error);
        warn sprintf "prepare-target failed for %s: %s\n",
          ( $entry->{target_full_path} || "<unknown target>" ),
          $error;
        return (
            undef,
            {
                error => $error,
                planned_action => $entry->{action},
                status => "failed",
                target_full_path => $entry->{target_full_path},
            }
        );
    }

    return (
        {
            %{$prepared},
            planned_action => $entry->{action},
            target_full_path => $entry->{target_full_path},
        },
        undef
    );
}

sub _ensure_target_project {
    my ( $client, $entry ) = @_;
    my $group_cache = $client->{group_path_cache} ||= {};
    my $namespace_state_cache = $client->{namespace_state_cache} ||= {};
    my $namespace_state;
    my $requested_target_full_path = _required_string(
        $entry->{target_full_path},
        "target_full_path",
    );
    my $target_full_path = $requested_target_full_path;
    my $target_namespace_path = $entry->{target_namespace_path};
    my $path_name = basename($target_full_path);
    my $display_name =
      defined $entry->{target_project_name}
      ? _required_string( $entry->{target_project_name}, "target_project_name" )
      : $path_name;
    my $read_request_opt = _gitlab_read_request_opt( $entry->{policy} );
    my $lookup_existing_project = sub {
        my ( $group_id, $project_full_path, $project_path_name ) = @_;
        my $project;
        if (
            !$project
            && $namespace_state
            && ref( $namespace_state->{projects} ) eq "HASH"
            && defined $project_full_path
          )
        {
            $project = $namespace_state->{projects}->{$project_full_path};
        }
        $project = _get_project( $client, $project_full_path )
          if !$project && defined $project_full_path;
        if ( !$project && defined $group_id && defined $project_full_path ) {
            $project = _find_project_by_namespace_and_path(
                $client,
                $group_id,
                $project_full_path,
                $project_path_name,
            );
        }
        return $project;
    };
    my $resolve_target_project_destination = sub {
        my ( $current_full_path, $current_namespace_path, $current_group_id, $allow_live_group_lookup ) = @_;
        my $hops = 0;
        while ( defined $current_full_path ) {
            my $project = $lookup_existing_project->(
                $current_group_id,
                $current_full_path,
                basename($current_full_path),
            );
            return ( $current_full_path, $current_namespace_path, $current_group_id, $project )
              if $project;

            my $conflicting_group_id = $group_cache->{$current_full_path};
            if (
                !defined $conflicting_group_id
                && $namespace_state
                && ref( $namespace_state->{groups} ) eq "HASH"
              )
            {
                $conflicting_group_id = $namespace_state->{groups}->{$current_full_path};
            }
            if ( !defined $conflicting_group_id && $allow_live_group_lookup ) {
                my $conflicting_group = _get_group(
                    $client,
                    $current_full_path,
                    $read_request_opt,
                );
                $conflicting_group_id = $conflicting_group->{id}
                  if ref($conflicting_group) eq "HASH";
            }
            last unless defined $conflicting_group_id;

            $current_namespace_path = $current_full_path;
            $current_group_id = $conflicting_group_id;
            $group_cache->{$current_namespace_path} = $current_group_id;
            $current_full_path = _join_path( $current_namespace_path, $path_name );
            $hops++;
            die "target namespace nesting exceeded for $requested_target_full_path\n"
              if $hops > 10;
        }

        return ( $current_full_path, $current_namespace_path, $current_group_id, undef );
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
    if ( defined $target_namespace_path ) {
        $namespace_state = _target_namespace_state(
            $client,
            $target_namespace_path,
            $entry->{policy},
        );
        if ( ref( $namespace_state->{groups} ) eq "HASH" ) {
            %{$group_cache} = ( %{ $namespace_state->{groups} }, %{$group_cache} );
        }
	    }
	    if (
        !$existing
        && $namespace_state
        && ref( $namespace_state->{projects} ) eq "HASH"
        && defined $target_full_path
      )
    {
        $existing = $namespace_state->{projects}->{$target_full_path};
    }
    elsif ( !$existing && defined $target_full_path ) {
        $existing = $lookup_existing_project->( undef, $target_full_path, $path_name );
    }
    my $target_group_id =
      defined $target_namespace_path
      ? $group_cache->{$target_namespace_path}
      : undef;
    if ( !$existing && defined $target_namespace_path ) {
        $target_group_id = _ensure_group_path(
            $client,
            $target_namespace_path,
            $group_cache,
        );
        if ( $namespace_state && ref( $namespace_state->{groups} ) eq "HASH" ) {
            $namespace_state->{groups}->{$target_namespace_path} = $target_group_id;
        }
        if (
            !$existing
            && !( $namespace_state && ref( $namespace_state->{projects} ) eq "HASH" )
          )
        {
            $existing = $lookup_existing_project->(
                $target_group_id,
                $target_full_path,
                $path_name,
            );
        }
    }
    if ( !$existing && defined $target_namespace_path ) {
        my $known_conflicting_group_id = $group_cache->{$target_full_path};
        if (
            !defined $known_conflicting_group_id
            && $namespace_state
            && ref( $namespace_state->{groups} ) eq "HASH"
          )
        {
            $known_conflicting_group_id = $namespace_state->{groups}->{$target_full_path};
        }
        if ( defined $known_conflicting_group_id ) {
            ( $target_full_path, $target_namespace_path, $target_group_id, $existing ) =
              $resolve_target_project_destination->(
                $target_full_path,
                $target_namespace_path,
                $target_group_id,
                JSON::PP::false,
              );
        }
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
                    name => $display_name,
                    namespace_id => $target_group_id,
                    path => basename($target_full_path),
                    visibility => "public",
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
            $project = $lookup_existing_project->(
                $target_group_id,
                $target_full_path,
                basename($target_full_path),
            );
            if ($project) {
                $created = JSON::PP::false;
            }
            else {
                my $invalid_namespace_error = _is_gitlab_invalid_namespace_error($create_error);
                my $path_conflict_error = _is_gitlab_path_conflict_error($create_error);
                my $refreshed_namespace = 0;
                if ( ( $invalid_namespace_error || $path_conflict_error ) && defined $target_namespace_path ) {
                    _clear_group_path_cache_tree( $group_cache, $target_namespace_path );
                    _clear_namespace_state_cache_tree( $namespace_state_cache, $target_namespace_path );
                    $namespace_state = _target_namespace_state(
                        $client,
                        $target_namespace_path,
                        $entry->{policy},
                    );
                    if ( ref( $namespace_state->{groups} ) eq "HASH" ) {
                        %{$group_cache} = ( %{ $namespace_state->{groups} }, %{$group_cache} );
                    }
                    $target_group_id = _ensure_group_path(
                        $client,
                        $target_namespace_path,
                        $group_cache,
                    );
                    $refreshed_namespace = 1;
                    if ($path_conflict_error) {
                        ( $target_full_path, $target_namespace_path, $target_group_id, $project ) =
                          $resolve_target_project_destination->(
                            $target_full_path,
                            $target_namespace_path,
                            $target_group_id,
                            JSON::PP::true,
                          );
                    }
                }
                if ($path_conflict_error && $refreshed_namespace) {
                    $project ||= $lookup_existing_project->(
                        $target_group_id,
                        $target_full_path,
                        basename($target_full_path),
                    );
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
                        $project = $lookup_existing_project->(
                            $target_group_id,
                            $target_full_path,
                            basename($target_full_path),
                        );
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
                        ( $target_full_path, $target_namespace_path, $target_group_id, $project ) =
                          $resolve_target_project_destination->(
                            $target_full_path,
                            $target_namespace_path,
                            $target_group_id,
                            JSON::PP::true,
                          );
                        $project ||= $lookup_existing_project->(
                            $target_group_id,
                            $target_full_path,
                            basename($target_full_path),
                        );
                    }
                }
                if ( !$created && !$project && $path_conflict_error ) {
                    die "gitlab project path conflict for $target_full_path: $create_error";
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

    if ( $project && $namespace_state && ref( $namespace_state->{projects} ) eq "HASH" ) {
        $namespace_state->{projects}->{$target_full_path} = $project;
    }

    return {
        created => $created,
        default_branch => defined $project->{default_branch} ? $project->{default_branch} : q{},
        project_id => $project->{id},
        requested_target_full_path => $requested_target_full_path,
        resolved_target_full_path => $target_full_path,
        resolved_target_namespace_path => $target_namespace_path,
        updated => $updated,
    };
}

sub _finalize_target_project {
    my ( $client, $project_id, $default_branch, $entry ) = @_;
    for my $branch_name ( @{ _configured_target_branches_to_protect( $entry->{policy} ) } ) {
        _ensure_target_branch_protected( $client, $project_id, $branch_name );
    }
    return 1;
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

sub _ensure_target_branch_protected {
    my ( $client, $project_id, $branch_name ) = @_;
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
    return 1 if _is_gitlab_already_exists_error($protect_error);
    die $protect_error;
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
        token => undef,
        username => undef,
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

sub _prepared_requires_finalize {
    my ( $prepared, $entry ) = @_;
    return 1 unless ref($prepared) eq "HASH";
    return scalar @{ _configured_target_branches_to_protect( $entry->{policy} ) } ? 1 : 0;
}

sub _index_prepared_payload {
    my ($payload) = @_;
    my ( %prepared, %failures );
    return ( \%prepared, \%failures ) unless ref($payload) eq "HASH";
    for my $item ( @{ $payload->{prepared} || [] } ) {
        next unless ref($item) eq "HASH";
        my $path = $item->{target_full_path};
        next unless defined $path && !ref($path) && length $path;
        $prepared{$path} = $item;
    }
    for my $item ( @{ $payload->{failures} || [] } ) {
        next unless ref($item) eq "HASH";
        my $path = $item->{target_full_path};
        next unless defined $path && !ref($path) && length $path;
        $failures{$path} = $item;
    }
    return ( \%prepared, \%failures );
}

sub _discover_remote_refs {
    my ( $source_url, $policy ) = @_;
    my $result = _run_command(
        [ "git", "ls-remote", "--heads", "--tags", "--symref", $source_url ],
        _git_command_options( $policy, JSON::PP::true )
    );
    $result->{status} == 0 or die "git ls-remote failed: $result->{output}\n";
    return _parse_remote_refs_output( $result->{output} );
}

sub _parse_remote_refs_output {
    my ($output) = @_;
    my %branches;
    my %tags;
    my $default_branch = "";
    for my $line ( split /\n/, $output || q{} ) {
        next unless $line;
        if ( $line =~ /\Aref:\s+refs\/heads\/([^\s]+)\s+HEAD\z/ ) {
            $default_branch = $1;
            next;
        }
        if ( $line =~ /\A([0-9a-f]{40})\s+refs\/heads\/(.+)\z/ ) {
            $branches{$2} = $1;
            next;
        }
        if ( $line =~ /\A([0-9a-f]{40})\s+refs\/tags\/(.+?)(\^\{\})?\z/ ) {
            my ( $oid, $name, $peeled ) = ( $1, $2, $3 );
            $tags{$name} = $oid if !exists $tags{$name} || defined $peeled;
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

sub _discover_remote_refs_if_exists {
    my ( $source_url, $policy ) = @_;
    my $result = _run_command(
        [ "git", "ls-remote", "--heads", "--tags", "--symref", $source_url ],
        _git_command_options( $policy, JSON::PP::true )
    );
    return _parse_remote_refs_output( $result->{output} ) if $result->{status} == 0;
    return undef if _ls_remote_reports_missing_repo( $result->{output} );
    die "git ls-remote failed: $result->{output}\n";
}

sub _ls_remote_reports_missing_repo {
    my ($output) = @_;
    return 0 unless defined $output && !ref($output) && length $output;
    return 0 if $output =~ /Authentication failed/i;
    return 0 if $output =~ /Access denied/i;
    return 0 if $output =~ /could not read Username/i;
    return 0 if $output =~ /forbidden/i;
    return 1 if $output =~ /not found/i;
    return 1 if $output =~ /does not appear to be a git repository/i;
    return 1 if $output =~ /could not be found/i;
    return 0;
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

sub _checkout_selected_ref {
    my ( $repo_dir, $selected ) = @_;
    if ( @{ $selected->{branches} || [] } ) {
        my $branch = $selected->{branches}->[0];
        my $result = _run_command(
            [ "git", "-C", $repo_dir, "checkout", "-f", $branch ],
            { timeout => 300 }
        );
        $result->{status} == 0 or die "git checkout failed for branch $branch: $result->{output}\n";
        return 1;
    }
    if ( @{ $selected->{tags} || [] } ) {
        my $tag = $selected->{tags}->[0];
        my $result = _run_command(
            [ "git", "-C", $repo_dir, "checkout", "--detach", "-f", sprintf( "refs/tags/%s^{commit}", $tag ) ],
            { timeout => 300 }
        );
        $result->{status} == 0 or die "git checkout failed for tag $tag: $result->{output}\n";
    }
    return 1;
}

sub _push_selected_refs {
    my ( $repo_dir, $selected, $policy, $default_branch, $target_sync_branch, $opt ) = @_;
    $opt ||= {};
    $target_sync_branch = _required_git_ref_name( $target_sync_branch, "target sync branch" );
    my %additional_branch_names = map { $_->{name} => 1 } @{ $policy->{additional_branches} || [] };
    my %selected_branch_names = map { $_ => 1 } @{ $selected->{branches} || [] };
    for my $branch ( @{ $selected->{branches} || [] } ) {
        next if $default_branch && $branch eq $default_branch && !$additional_branch_names{$branch};
        _push_target_refspec(
            $repo_dir,
            "refs/heads/$branch:refs/heads/$branch",
            "branch $branch",
            $policy,
            $opt,
        );
    }
    if ( $default_branch && $selected_branch_names{$default_branch} ) {
        _push_target_refspec(
            $repo_dir,
            "refs/heads/$default_branch:refs/heads/$target_sync_branch",
            "managed sync branch $target_sync_branch",
            $policy,
            $opt,
        );
    }
    for my $tag ( @{ $selected->{tags} || [] } ) {
        _push_target_refspec(
            $repo_dir,
            "refs/tags/$tag:refs/tags/$tag",
            "tag $tag",
            $policy,
            $opt,
        );
    }
}

sub _push_target_refspec {
    my ( $repo_dir, $refspec, $label, $policy, $opt ) = @_;
    $opt ||= {};
    my $result = _run_command(
        [
            "git", "-C", $repo_dir, "push", "--force", "target",
            $refspec
        ],
        _git_command_options( $policy, JSON::PP::true )
    );
    if ( $result->{status} != 0 && _git_output_mentions_lfs($result->{output}) ) {
        if ( ref( $opt->{on_missing_lfs} ) eq "CODE" ) {
            $opt->{on_missing_lfs}->();
        }
        else {
            _run_command(
                [ "git", "-C", $repo_dir, "lfs", "push", "--all", "target" ],
                _git_command_options( $policy, JSON::PP::true )
            );
        }
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

sub _sync_lfs_objects {
    my ( $repo_dir, $selected, $policy ) = @_;
    _prepare_lfs( $repo_dir, $policy );
    for my $branch ( @{ $selected->{branches} || [] } ) {
        my $lfs_result = _run_command(
            [ "git", "-C", $repo_dir, "lfs", "fetch", "source", "refs/heads/$branch" ],
            _git_command_options( $policy, JSON::PP::true )
        );
        $lfs_result->{status} == 0 or die "git lfs fetch failed for branch $branch: $lfs_result->{output}\n";
    }
    for my $tag ( @{ $selected->{tags} || [] } ) {
        my $lfs_result = _run_command(
            [ "git", "-C", $repo_dir, "lfs", "fetch", "source", "refs/tags/$tag" ],
            _git_command_options( $policy, JSON::PP::true )
        );
        $lfs_result->{status} == 0 or die "git lfs fetch failed for tag $tag: $lfs_result->{output}\n";
    }
    _run_git_lfs_push_all( $repo_dir, $policy );
    return 1;
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
    my $result = _run_command( [ "git", "-C", $repo_dir, "lfs", "ls-files", "--all" ], { timeout => 120 } );
    return 0 if $result->{status} != 0;
    return $result->{output} =~ /\S/ ? 1 : 0;
}

sub _selected_refs_requiring_sync {
    my ( $selected, $source_available, $target_available, $default_branch, $target_sync_branch, $policy ) = @_;
    return { branches => [], tags => [] } unless ref($selected) eq "HASH";
    return { branches => [], tags => [] } unless ref($source_available) eq "HASH";
    return { branches => [], tags => [] } unless ref($target_available) eq "HASH";
    $target_sync_branch = _required_git_ref_name( $target_sync_branch, "target sync branch" );

    my @branches_to_sync;
    my @tags_to_sync;
    my %additional_branch_names = map { $_->{name} => 1 } @{ $policy->{additional_branches} || [] };

    for my $branch ( @{ $selected->{branches} || [] } ) {
        my $source_oid = $source_available->{branches}->{$branch};
        next unless defined $source_oid && length $source_oid;
        if ( $default_branch && $branch eq $default_branch ) {
            my $target_sync_oid = $target_available->{branches}->{$target_sync_branch};
            if ( !defined $target_sync_oid || $target_sync_oid ne $source_oid ) {
                push @branches_to_sync, $branch;
                next;
            }
            next unless $additional_branch_names{$branch};
        }
        my $target_oid = $target_available->{branches}->{$branch};
        push @branches_to_sync, $branch
          unless defined $target_oid && $target_oid eq $source_oid;
    }

    for my $tag ( @{ $selected->{tags} || [] } ) {
        my $source_oid = $source_available->{tags}->{$tag};
        next unless defined $source_oid && length $source_oid;
        my $target_oid = $target_available->{tags}->{$tag};
        push @tags_to_sync, $tag
          unless defined $target_oid && $target_oid eq $source_oid;
    }

    return {
        branches => \@branches_to_sync,
        tags => \@tags_to_sync,
    };
}

sub _selected_refs_already_synced {
    my ( $selected, $source_available, $target_available, $default_branch, $target_sync_branch, $policy ) = @_;
    return 0 unless ref($selected) eq "HASH";
    return 0 unless ref($source_available) eq "HASH";
    return 0 unless ref($target_available) eq "HASH";
    my $pending = _selected_refs_requiring_sync(
        $selected,
        $source_available,
        $target_available,
        $default_branch,
        $target_sync_branch,
        $policy,
    );
    return !( @{ $pending->{branches} || [] } || @{ $pending->{tags} || [] } );
}

sub _gitlab_request {
    my ( $client, $method, $path, $payload, $opt ) = @_;
    $opt ||= {};
    if ( my $blocked = _gitlab_client_blocked_error($client) ) {
        die $blocked =~ /\n\z/ ? $blocked : $blocked . "\n";
    }
    my $url = $client->{base_url} . "/api/v4" . $path;
    my $attempts = $opt->{retry_attempts} || $DEFAULTS{retry_attempts};
    my $backoff = $opt->{retry_backoff_seconds} || $DEFAULTS{retry_backoff_seconds};
    my $max_time = $opt->{max_time_seconds} || 60;
    my $timeout = $opt->{timeout_seconds} || 90;
    my $content = defined $payload ? $JSON->encode($payload) : undef;
    for my $attempt ( 1 .. $attempts ) {
        _wait_for_gitlab_rate_limit_window($client);
        my ( $headers_fh, $headers_path ) = tempfile();
        close $headers_fh;
        my @command = (
            "curl",
            "--silent",
            "--show-error",
            "--location",
            "--max-time",
            $max_time,
            "--dump-header",
            $headers_path,
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
        my $headers = _read_http_headers_file($headers_path);
        unlink $headers_path;
        if ( $response->{status} == 0 && $http_status >= 200 && $http_status < 300 ) {
            _record_gitlab_rate_limit_state( $client, $http_status, $headers );
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
            _sleep_seconds(
                _gitlab_retry_delay_seconds(
                    $http_status,
                    $headers,
                    $backoff * $attempt,
                )
            );
            next;
        }

        _record_gitlab_rate_limit_state( $client, $http_status, $headers );
        my $status_label = $http_status || $response->{status};
        my $message = defined $body && length $body ? $body : ( $response->{output} || "unknown error" );
        my $error = "gitlab request failed [$status_label] $method $path: $message\n";
        _mark_gitlab_client_blocked( $client, $error )
          if _is_gitlab_account_blocked_error($message);
        die $error;
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

sub _current_epoch {
    return time();
}

sub _sleep_seconds {
    my ($seconds) = @_;
    return 1 unless defined $seconds;
    return 1 if $seconds <= 0;
    sleep($seconds);
    return 1;
}

sub _wait_for_gitlab_rate_limit_window {
    my ($client) = @_;
    return 1 unless ref($client) eq "HASH";
    my $resume_epoch = $client->{rate_limit_resume_after_epoch} || 0;
    my $now = _current_epoch();
    if ( $resume_epoch > $now ) {
        _sleep_seconds( $resume_epoch - $now );
    }
    delete $client->{rate_limit_resume_after_epoch}
      if ( $client->{rate_limit_resume_after_epoch} || 0 ) <= _current_epoch();
    return 1;
}

sub _gitlab_retry_delay_seconds {
    my ( $http_status, $headers, $fallback_delay ) = @_;
    if ( $http_status == 429 && ref($headers) eq "HASH" ) {
        my $retry_after = _positive_int_from_header( $headers->{"retry-after"} );
        return $retry_after if defined $retry_after && $retry_after > 0;
        my $reset_epoch = _positive_int_from_header( $headers->{"ratelimit-reset"} );
        if ( defined $reset_epoch ) {
            my $delay = $reset_epoch - _current_epoch();
            return $delay > 0 ? $delay : 1;
        }
    }
    return $fallback_delay;
}

sub _record_gitlab_rate_limit_state {
    my ( $client, $http_status, $headers ) = @_;
    return 1 unless ref($client) eq "HASH";
    return 1 unless ref($headers) eq "HASH";
    my $resume_epoch;
    if ( $http_status == 429 ) {
        my $retry_after = _positive_int_from_header( $headers->{"retry-after"} );
        if ( defined $retry_after && $retry_after > 0 ) {
            $resume_epoch = _current_epoch() + $retry_after;
        }
        else {
            my $reset_epoch = _positive_int_from_header( $headers->{"ratelimit-reset"} );
            $resume_epoch = $reset_epoch if defined $reset_epoch;
        }
    }
    else {
        my $remaining = _positive_int_from_header( $headers->{"ratelimit-remaining"} );
        my $reset_epoch = _positive_int_from_header( $headers->{"ratelimit-reset"} );
        if ( defined $remaining && defined $reset_epoch && $remaining <= 0 && $reset_epoch > _current_epoch() ) {
            $resume_epoch = $reset_epoch;
        }
    }
    if ( defined $resume_epoch && $resume_epoch > _current_epoch() ) {
        $client->{rate_limit_resume_after_epoch} = $resume_epoch;
    }
    return 1;
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

sub _read_http_headers_file {
    my ($path) = @_;
    return {} unless defined $path && !ref($path) && length $path && -f $path;
    open( my $fh, "<:encoding(UTF-8)", $path ) or die "unable to read $path\n";
    my $text = do { local $/; <$fh> };
    close $fh;
    return _parse_http_headers( $text || q{} );
}

sub _parse_http_headers {
    my ($text) = @_;
    my %headers;
    return \%headers unless defined $text && !ref($text) && length $text;
    my @blocks = split /\r?\n\r?\n/, $text;
    for my $block (@blocks) {
        my @lines = split /\r?\n/, $block;
        next unless @lines;
        next unless ( $lines[0] || q{} ) =~ /\AHTTP\/\d/;
        for my $line ( @lines[ 1 .. $#lines ] ) {
            next unless defined $line && length $line;
            my ( $name, $value ) = split /:\s*/, $line, 2;
            next unless defined $name && defined $value;
            $headers{ lc $name } = $value;
        }
    }
    return \%headers;
}

sub _positive_int_from_header {
    my ($value) = @_;
    return undef unless defined $value && !ref($value);
    $value =~ s/\A\s+//;
    $value =~ s/\s+\z//;
    return undef unless $value =~ /\A\d+\z/;
    return 0 + $value;
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
    defined $text or die "empty JSON file: $path\n";
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    length $text or die "empty JSON file: $path\n";
    my $decoded = eval { $JSON->decode($text) };
    die "unable to parse JSON file $path: $@" if $@;
    return $decoded;
}

sub _read_jsonl {
    my ($path) = @_;
    open( my $fh, "<:encoding(UTF-8)", $path ) or die "unable to read $path\n";
    my @rows;
    my $line_no = 0;
    while ( my $line = <$fh> ) {
        $line_no++;
        $line =~ s/\s+\z//;
        next unless length $line;
        my $decoded = eval { $JSON->decode($line) };
        die "unable to parse JSONL file $path line $line_no: $@" if $@;
        push @rows, $decoded;
    }
    close $fh;
    return \@rows;
}

sub _read_config_payload {
    my ($path) = @_;
    return _read_json($path) if $path =~ /\.json\z/;
    return _read_jsonl($path) if $path =~ /\.jsonl\z/;

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
    my ( $config, $target_paths ) = @_;
    return undef unless ref( $config->{exclusions} ) eq "HASH";
    my %seen;
    for my $candidate (
        $target_paths->{target_full_path},
        $target_paths->{requested_target_full_path},
        $target_paths->{target_relative_project_path},
        $target_paths->{requested_target_relative_project_path},
      )
    {
        next unless defined $candidate && length $candidate;
        next if $seen{$candidate}++;
        return $config->{exclusions}->{$candidate}
          if exists $config->{exclusions}->{$candidate};
    }
    return undef;
}

sub _source_group_exclusion_reason {
    my ( $config, $source_group_path ) = @_;
    return undef unless ref($config) eq "HASH";
    return undef unless defined $source_group_path && length $source_group_path;
    return undef unless ref( $config->{source_group_exclusions} ) eq "HASH";
    return $config->{source_group_exclusions}->{$source_group_path}
      if exists $config->{source_group_exclusions}->{$source_group_path};
    return undef;
}

sub _source_group_notice_entry {
    my ( $namespace, $base_url, $source_group_path, $reason ) = @_;
    my $entry = {
        base_url => $base_url,
        namespace_name => $namespace->{name},
        source_group_path => $source_group_path,
        target_namespace_path => _join_path( $namespace->{target_namespace_path}, $source_group_path ),
    };
    $entry->{reason} = $reason if defined $reason && length $reason;
    return $entry;
}

sub _gitlab_safe_relative_project_path {
    my ($relative_path) = @_;
    $relative_path = _required_string( $relative_path, "relative project path" );
    my @segments = split m{/}, $relative_path;
    @segments or die "relative project path must contain at least one path segment\n";
    return join "/", map { _gitlab_safe_path_segment($_) } @segments;
}

sub _gitlab_safe_group_path {
    my ($group_path) = @_;
    $group_path = _required_relative_namespace_path( $group_path, "target group path" );
    return _gitlab_safe_relative_project_path($group_path);
}

sub _gitlab_safe_path_segment {
    my ($segment) = @_;
    $segment = _required_string( $segment, "target path segment" );
    return $segment unless defined _gitlab_invalid_path_segment_reason($segment);
    return "x-" . unpack( "H*", $segment );
}

sub _resolve_explicit_project_target_paths {
    my ( $project, $namespace ) = @_;
    my $requested_target_namespace_path = _required_relative_namespace_path(
        $project->{target_group_path},
        "target_group_path",
    );
    my $target_namespace_path =
      _gitlab_safe_group_path($requested_target_namespace_path);
    my $target_project_name = _required_path_segment( $project->{name}, "project.name" );
    my $target_project_path = _gitlab_safe_path_segment($target_project_name);
    my $requested_target_full_path = _join_path(
        $requested_target_namespace_path,
        $target_project_name,
    );
    my $target_full_path = _join_path(
        $target_namespace_path,
        $target_project_path,
    );
    my $requested_target_relative_project_path = $requested_target_full_path;
    my $target_relative_project_path = $target_full_path;

    if ( ref($namespace) eq "HASH" ) {
        my $target_owner_path = $namespace->{target_owner_path};
        if ( defined $target_owner_path && !ref($target_owner_path) && length $target_owner_path ) {
            my $requested_prefix =
              _resolve_requested_target_root_group_path($namespace) . "/";
            if ( index( $requested_target_full_path, $requested_prefix ) == 0 ) {
                $requested_target_relative_project_path =
                  substr( $requested_target_full_path, length($requested_prefix) );
            }
            my $prefix = _resolve_target_root_group_path($namespace) . "/";
            if ( index( $target_full_path, $prefix ) == 0 ) {
                $target_relative_project_path =
                  substr( $target_full_path, length($prefix) );
            }
        }
    }

    return {
        requested_target_full_path => $requested_target_full_path,
        requested_target_relative_project_path => $requested_target_relative_project_path,
        target_full_path => $target_full_path,
        target_project_name => $target_project_name,
        target_relative_project_path => $target_relative_project_path,
        target_namespace_path => $target_namespace_path,
    };
}

sub _resolve_namespace_project_target_paths {
    my ( $namespace, $source_group_path, $source_full_path ) = @_;
    my $requested_target_root_path =
      _resolve_requested_target_root_group_path($namespace);
    my $target_root_path = _resolve_target_root_group_path($namespace);
    my $relative_path = _relative_path( $source_group_path, $source_full_path );
    my @source_segments = split m{/}, $relative_path;
    my $target_project_name = $source_segments[-1];
    my $requested_target_namespace_path = _required_relative_namespace_path(
        $namespace->{target_namespace_path},
        "target_namespace_path",
    );
    my $requested_target_relative_project_path =
      _join_path( $requested_target_namespace_path, $relative_path );
    my $requested_target_full_path =
      _join_path( $requested_target_root_path, $requested_target_relative_project_path );
    my $gitlab_safe_relative_path = _gitlab_safe_relative_project_path($relative_path);
    my $target_namespace_root =
      _gitlab_safe_group_path($requested_target_namespace_path);
    my $target_relative_project_path =
      _join_path( $target_namespace_root, $gitlab_safe_relative_path );
    my $target_full_path = _join_path( $target_root_path, $target_relative_project_path );
    return {
        requested_target_full_path => $requested_target_full_path,
        requested_target_relative_project_path => $requested_target_relative_project_path,
        target_full_path => $target_full_path,
        target_project_name => $target_project_name,
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
    _assert_path_segment_shape( $value, $label );
    return $value;
}

sub _required_group_path_min_segments {
    my ( $value, $label, $minimum_segments ) = @_;
    $value = _required_string( $value, $label );
    my @segments = split m{/}, $value, -1;
    @segments >= $minimum_segments
      or die "$label must contain at least $minimum_segments path segment(s)\n";
    _assert_path_segment_shape( $_, "$label path segment" ) for @segments;
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

sub _required_git_ref_name {
    my ( $value, $label ) = @_;
    $value = _required_string( $value, $label );
    $value =~ /\A[0-9A-Za-z._-]+(?:\/[0-9A-Za-z._-]+)*\z/
      or die "$label must be a Git ref name\n";
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

sub _reject_project_only_key {
    my ( $payload, $label, $key ) = @_;
    return unless exists $payload->{$key};
    die "$label.$key is supported only in projects.yml explicit project entries\n";
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
    my @segments = split m{/}, $relative, -1;
    @segments or die "invalid relative project path: $relative\n";
    eval {
        _assert_path_segment_shape( $_, "relative project path segment" ) for @segments;
        1;
    } or die "invalid relative project path: $relative\n";
    return $relative;
}

sub _assert_path_segment_shape {
    my ( $value, $label ) = @_;
    defined $value && !ref($value)
      or die "$label must be a single path segment\n";
    length $value
      or die "$label must be a single path segment\n";
    $value !~ m{/}
      or die "$label must be a single path segment\n";
    $value ne "." && $value ne ".."
      or die "$label must not be '.' or '..'\n";
    $value !~ /[\x00-\x1F\x7F]/
      or die "$label must not contain control characters\n";
    return $value;
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

sub _discover_remote_refs_if_exists_from_urls {
    my ( $candidate_urls, $policy, $chosen_source_url_ref ) = @_;
    ref($candidate_urls) eq "ARRAY" or die "candidate source URLs must be a list\n";
    my %seen;
    my @candidates = grep { defined $_ && length $_ && !$seen{$_}++ } @{$candidate_urls};
    @candidates or die "at least one candidate source URL is required\n";

    my $last_error = q{};
    for my $candidate (@candidates) {
        my $available = eval { _discover_remote_refs_if_exists( $candidate, $policy ) };
        if ($available) {
            $$chosen_source_url_ref = $candidate if defined $chosen_source_url_ref;
            return $available;
        }
        if ( !$@ ) {
            $$chosen_source_url_ref = $candidate if defined $chosen_source_url_ref;
            return undef;
        }
        $last_error ||= $@;
    }

    die $last_error if length $last_error;
    return undef;
}

sub _discover_target_remote_refs_if_exists {
    my ( $target_client, $target_full_path, $policy ) = @_;
    my $anonymous_url =
      _project_git_url( $target_client->{base_url}, $target_full_path );
    my $authenticated_url = _maybe_auth_url(
        $anonymous_url,
        $target_client->{read_username},
        $target_client->{read_token},
    );
    return _discover_remote_refs_if_exists_from_urls(
        [ $anonymous_url, $authenticated_url ],
        $policy,
        undef,
    );
}

sub _git_output_mentions_lfs {
    my ($output) = @_;
    return 0 unless defined $output && !ref($output) && length $output;
    return 1 if $output =~ /\bGit LFS\b/i;
    return 1 if $output =~ /\bLFS objects are missing\b/i;
    return 1 if $output =~ /\bLocking support detected on remote\b/i;
    return 1 if $output =~ /\blfs\.allowincompletepush\b/i;
    return 1 if $output =~ /\bmissing or corrupt local objects\b/i;
    return 1 if $output =~ /\ballocated storage for your project\b/i;
    return 0;
}

sub _git_output_reports_lfs_storage_quota_exceeded {
    my ($output) = @_;
    return 0 unless defined $output && !ref($output) && length $output;
    return 1 if $output =~ /would exceed the allocated storage for your project/i;
    return 1 if $output =~ /Contact your GitLab administrator for more information/i;
    return 0;
}

sub _git_output_reports_missing_source_credentials {
    my ($output) = @_;
    return 0 unless defined $output && !ref($output) && length $output;
    return 1 if $output =~ /could not read Username .* No such device or address/i;
    return 1 if $output =~ /could not read Username/i;
    return 0;
}

sub _git_output_reports_lfs_locking_support {
    my ($output) = @_;
    return 0 unless defined $output && !ref($output) && length $output;
    return 1 if $output =~ /Locking support detected on remote/i;
    return 0;
}

sub _git_output_reports_lfs_incomplete_push {
    my ($output) = @_;
    return 0 unless defined $output && !ref($output) && length $output;
    return 1 if $output =~ /\blfs\.allowincompletepush\b/i;
    return 1 if $output =~ /missing or corrupt local objects/i;
    return 1 if $output =~ /Git LFS upload missing objects/i;
    return 1 if $output =~ /\bLFS objects are missing\b/i;
    return 1 if $output =~ /git lfs push --all/i;
    return 0;
}

sub _extract_lfs_locksverify_config_key {
    my ($output) = @_;
    return undef unless defined $output && !ref($output) && length $output;
    return $1 if $output =~ /git config\s+([^\s]+\.locksverify)\s+true/i;
    return undef;
}

sub _set_local_git_config {
    my ( $repo_dir, $key, $value, $policy ) = @_;
    my $result = _run_command(
        [ "git", "-C", $repo_dir, "config", "--local", $key, $value ],
        {
            timeout => 60,
        }
    );
    $result->{status} == 0 or die "git config failed for $key: $result->{output}\n";
    return 1;
}

sub _apply_git_lfs_remediations {
    my ( $repo_dir, $policy, $output, $state ) = @_;
    $state ||= {};
    my $applied = 0;
    if ( _git_output_reports_lfs_locking_support($output) ) {
        my $key = _extract_lfs_locksverify_config_key($output);
        if ( defined $key && length $key && !( $state->{locksverify_keys} ||= {} )->{$key}++ ) {
            _set_local_git_config( $repo_dir, $key, "true", $policy );
            $applied = 1;
        }
    }
    if ( _git_output_reports_lfs_incomplete_push($output) && !$state->{allowincompletepush}++ ) {
        _set_local_git_config( $repo_dir, "lfs.allowincompletepush", "true", $policy );
        $applied = 1;
    }
    return $applied;
}

sub _run_git_lfs_push_all {
    my ( $repo_dir, $policy ) = @_;
    my %remediation_state;
    while (1) {
        my $lfs_result = _run_command(
            [ "git", "-C", $repo_dir, "lfs", "push", "--all", "target" ],
            _git_command_options( $policy, JSON::PP::true )
        );
        return 1 if $lfs_result->{status} == 0;

        my $applied = _apply_git_lfs_remediations(
            $repo_dir,
            $policy,
            $lfs_result->{output},
            \%remediation_state,
        );
        next if $applied;

        if ( _git_output_reports_lfs_storage_quota_exceeded( $lfs_result->{output} ) ) {
            die "git lfs push failed: target repository storage quota exceeded: $lfs_result->{output}\n";
        }
        die "git lfs push failed: $lfs_result->{output}\n";
    }
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
    return 1 if $text =~ /\bHTTP 5\d\d\b/i;
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
