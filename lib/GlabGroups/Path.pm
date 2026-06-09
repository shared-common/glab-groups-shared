package GlabGroups::Path;

use strict;
use warnings;

use Exporter qw(import);

our @EXPORT_OK = qw(
  _base_url_host
  _defaulted_bounded_positive_int
  _defaulted_positive_int
  _is_gitiles_host
  _join_path
  _optional_bounded_positive_int
  _optional_positive_int
  _positive_int
  _relative_path
  _required_group_path_min_segments
  _required_https_url
  _required_path_segment
  _required_relative_namespace_path
  _required_relative_project_path
  _required_string
  _source_root_key
  _split_source_url
  _strip_optional_git_suffix
);

sub _required_string {
    my ( $value, $label ) = @_;
    defined $value or die "$label is required\n";
    ref($value) and die "$label must be a string\n";
    $value =~ s/\A\s+// if !ref($value);
    $value =~ s/\s+\z// if !ref($value);
    length $value or die "$label must not be empty\n";
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

1;
