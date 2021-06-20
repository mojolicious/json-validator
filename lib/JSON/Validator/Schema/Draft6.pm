package JSON::Validator::Schema::Draft6;
use Mojo::Base 'JSON::Validator::Schema';

use JSON::Validator::Schema::Draft4;
use JSON::Validator::Util qw(E data_type is_type prefix_errors);

has id => sub {
  my $data = shift->data;
  return is_type($data, 'HASH') ? $data->{'$id'} || '' : '';
};

has specification => 'http://json-schema.org/draft-06/schema#';

sub _build_formats {
  return {
    'date-time'             => JSON::Validator::Formats->can('check_date_time'),
    'email'                 => JSON::Validator::Formats->can('check_email'),
    'hostname'              => JSON::Validator::Formats->can('check_hostname'),
    'ipv4'                  => JSON::Validator::Formats->can('check_ipv4'),
    'ipv6'                  => JSON::Validator::Formats->can('check_ipv6'),
    'json-pointer'          => JSON::Validator::Formats->can('check_json_pointer'),
    'regex'                 => JSON::Validator::Formats->can('check_regex'),
    'relative-json-pointer' => JSON::Validator::Formats->can('check_relative_json_pointer'),
    'uri'                   => JSON::Validator::Formats->can('check_uri'),
    'uri-reference'         => JSON::Validator::Formats->can('check_uri_reference'),
    'uri-template'          => JSON::Validator::Formats->can('check_uri_template'),
  };
}

sub _id_key {'$id'}

sub _validate_number_max {
  my ($self, $value, $state, $expected) = @_;

  my $cmp_with = $state->{schema}{maximum};
  return E $state->{path}, [$expected => maximum => $value, $cmp_with] if defined $cmp_with and $value > $cmp_with;

  $cmp_with = $state->{schema}{exclusiveMaximum};
  return E $state->{path}, [$expected => ex_maximum => $value, $cmp_with] if defined $cmp_with and $value >= $cmp_with;

  return;
}

sub _validate_number_min {
  my ($self, $value, $state, $expected) = @_;

  my $cmp_with = $state->{schema}{minimum};
  return E $state->{path}, [$expected => minimum => $value, $cmp_with] if defined $cmp_with and $value < $cmp_with;

  $cmp_with = $state->{schema}{exclusiveMinimum};
  return E $state->{path}, [$expected => ex_minimum => $value, $cmp_with] if defined $cmp_with and $value <= $cmp_with;

  return;
}

sub _validate_type_array {
  my ($self, $data, $state) = @_;
  return E $state->{path}, [array => type => data_type $data] if ref $data ne 'ARRAY';

  return (
    $self->_validate_type_array_min_max($_[1], $state),
    $self->_validate_type_array_unique($_[1], $state),
    $self->_validate_type_array_contains($_[1], $state),
    $self->_validate_type_array_items($_[1], $state),
  );
}

sub _validate_type_array_contains {
  my ($self, $data, $state) = @_;
  return unless exists $state->{schema}{contains};

  my (@e, @errors);
  for my $i (0 .. @$data - 1) {
    my @tmp = $self->_validate($data->[$i],
      $self->_state($state, path => "$state->{path}/$i", schema => $state->{schema}{contains}));
    push @e, \@tmp if @tmp;
  }

  push @errors, map {@$_} @e if @e >= @$data;
  push @errors, E $state->{path}, [array => 'contains'] if not @$data;
  return @errors;
}

sub _validate_type_object {
  my ($self, $data, $state) = @_;
  return E $state->{path}, [object => type => data_type $data] if ref $data ne 'HASH';

  return (
    $self->_validate_type_object_min_max($_[1], $state),
    $self->_validate_type_object_names($_[1], $state),
    $self->_validate_type_object_properties($_[1], $state),
    $self->_validate_type_object_dependencies($_[1], $state),
  );
}

sub _validate_type_object_names {
  my ($self, $data, $state) = @_;
  return unless exists $state->{schema}{propertyNames};

  my @errors;
  for my $name (keys %$data) {
    next unless my @e = $self->_validate($name, $self->_state($state, schema => $state->{schema}{propertyNames}));
    push @errors, prefix_errors propertyName => map [$name, $_], @e;
  }

  return @errors;
}

*_validate_type_array_items         = \&JSON::Validator::Schema::Draft4::_validate_type_array_items;
*_validate_type_array_min_max       = \&JSON::Validator::Schema::Draft4::_validate_type_array_min_max;
*_validate_type_array_unique        = \&JSON::Validator::Schema::Draft4::_validate_type_array_unique;
*_validate_type_object_dependencies = \&JSON::Validator::Schema::Draft4::_validate_type_object_dependencies;
*_validate_type_object_min_max      = \&JSON::Validator::Schema::Draft4::_validate_type_object_min_max;
*_validate_type_object_properties   = \&JSON::Validator::Schema::Draft4::_validate_type_object_properties;

1;

=encoding utf8

=head1 NAME

JSON::Validator::Schema::Draft6 - JSON-Schema Draft 6

=head1 SYNOPSIS

See L<JSON::Validator::Schema/SYNOPSIS>.

=head1 DESCRIPTION

This class represents
L<https://json-schema.org/specification-links.html#draft-6>.

=head1 ATTRIBUTES

=head2 specification

  my $str = $schema->specification;

Defaults to "L<http://json-schema.org/draft-06/schema#>".

=head1 SEE ALSO

L<JSON::Validator::Schema>.

=cut
