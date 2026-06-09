package GlabGroups::Source;

use strict;
use warnings;

use Exporter qw(import);

use GlabGroups::Path qw(
  _base_url_host
  _is_gitiles_host
  _join_path
  _source_root_key
  _split_source_url
  _strip_optional_git_suffix
);

our @EXPORT_OK = qw(
  _extract_root_repo_path
  _fallback_clone_url
  _parse_source_project_url
  _parse_source_url
  _project_git_url
);

sub _parse_source_url {
    my ( $url, $is_gitlab_instance_root_cb ) = @_;
    my ( $base_url, $path ) = _split_source_url($url);
    my $host = _base_url_host($base_url);

    if ( $host eq "github.com" ) {
        my @segments = split m{/}, $path;
        @segments == 1
          or die "GitHub source URL must point to exactly one organization path: $url\n";
        return {
            kind => "github_org",
            base_url => $base_url,
            root_path => $segments[0],
        };
    }

    if ( length $path ) {
        return {
            kind => "gitlab_group",
            base_url => $base_url,
            root_path => $path,
        };
    }

    if ( _is_gitiles_host($base_url) ) {
        return {
            kind => "gitiles_root",
            base_url => $base_url,
            root_path => q{},
        };
    }

    if ( $is_gitlab_instance_root_cb && $is_gitlab_instance_root_cb->($base_url) ) {
        return {
            kind => "gitlab_instance_root",
            base_url => $base_url,
            root_path => q{},
        };
    }

    return {
        kind => "cgit_root",
        base_url => $base_url,
        root_path => q{},
    };
}

sub _parse_source_project_url {
    my ( $url, $project_name ) = @_;
    my ( $base_url, $path ) = _split_source_url($url);
    my $host = _base_url_host($base_url);
    my @segments = grep { length } split m{/}, $path;

    if ( $host eq "github.com" ) {
        @segments == 2
          or die "GitHub project URL must point to exactly one repository path: $url\n";
        my $repo_name = _strip_optional_git_suffix( $segments[1] );
        return {
            base_url => $base_url,
            clone_url => $base_url . "/" . $segments[0] . "/" . $repo_name . ".git",
            group_path => $segments[0],
            fallback_clone_url => undef,
            kind => "github_project",
            path_with_namespace => join( "/", $segments[0], $repo_name ),
        };
    }

    if ( @segments >= 2 && _strip_optional_git_suffix( $segments[-1] ) eq $project_name ) {
        my $normalized_name = _strip_optional_git_suffix( $segments[-1] );
        return {
            base_url => $base_url,
            clone_url => $url,
            fallback_clone_url => $url =~ /\.git\z/ ? undef : $url . ".git",
            group_path => join( "/", @segments[ 0 .. $#segments - 1 ] ),
            kind => "git_project",
            path_with_namespace => join( "/", @segments[ 0 .. $#segments - 1 ], $normalized_name ),
        };
    }

    my $root_key = _source_root_key($base_url);
    return {
        base_url => $base_url,
        clone_url => $url,
        fallback_clone_url => $url =~ /\.git\z/ ? undef : $url . ".git",
        group_path => $root_key,
        kind => "git_project",
        path_with_namespace => _join_path( $root_key, $project_name ),
    };
}

sub _extract_root_repo_path {
    my ( $href, $text, $opt ) = @_;
    $opt ||= {};
    return undef unless defined $href;
    return undef if $href =~ /\?/;
    return undef if $href =~ m{\A(?:https?:)?//}i;
    my $candidate = $href;
    $candidate =~ s{#.*\z}{};
    $candidate =~ s{\A/+}{};
    $candidate =~ s{/\z}{};
    return undef unless length $candidate;
    return undef if $candidate =~ /\A(?:about|favicon\.ico|robots\.txt|cgit\.(?:css|png))\z/i;
    if ( !$opt->{allow_nested_paths} ) {
        return undef if $candidate =~ m{/};
        return undef unless $candidate =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/;
        return $candidate;
    }
    return undef unless $candidate =~ /\A[A-Za-z0-9][A-Za-z0-9._-]*(?:\/[A-Za-z0-9][A-Za-z0-9._-]*)*\z/;
    return $candidate;
}

sub _project_git_url {
    my ( $base_url, $project_path ) = @_;
    return $base_url . "/" . $project_path . ".git";
}

sub _fallback_clone_url {
    my ($url) = @_;
    return undef unless defined $url && length $url;
    return undef if $url =~ /\.git\z/;
    return $url . ".git";
}

1;
