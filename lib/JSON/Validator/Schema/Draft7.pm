package JSON::Validator::Schema::Draft7;
use Mojo::Base 'JSON::Validator::Schema';

use JSON::Validator::Schema::Draft4;
use JSON::Validator::Schema::Draft6;
use JSON::Validator::Util qw(E is_type);

has id => sub {
  my $data = shift->data;
  return is_type($data, 'HASH') ? $data->{'$id'} || '' : '';
};

has specification => 'http://json-schema.org/draft-07/schema#';

sub _build_formats {
  return {
    'date'                  => JSON::Validator::Formats->can('check_date'),
    'date-time'             => JSON::Validator::Formats->can('check_date_time'),
    'email'                 => JSON::Validator::Formats->can('check_email'),
    'hostname'              => JSON::Validator::Formats->can('check_hostname'),
    'idn-email'             => JSON::Validator::Formats->can('check_idn_email'),
    'idn-hostname'          => JSON::Validator::Formats->can('check_idn_hostname'),
    'ipv4'                  => JSON::Validator::Formats->can('check_ipv4'),
    'ipv6'                  => JSON::Validator::Formats->can('check_ipv6'),
    'iri'                   => JSON::Validator::Formats->can('check_iri'),
    'iri-reference'         => JSON::Validator::Formats->can('check_iri_reference'),
    'json-pointer'          => JSON::Validator::Formats->can('check_json_pointer'),
    'regex'                 => JSON::Validator::Formats->can('check_regex'),
    'relative-json-pointer' => JSON::Validator::Formats->can('check_relative_json_pointer'),
    'time'                  => JSON::Validator::Formats->can('check_time'),
    'uri'                   => JSON::Validator::Formats->can('check_uri'),
    'uri-reference'         => JSON::Validator::Formats->can('check_uri_reference'),
    'uri-template'          => JSON::Validator::Formats->can('check_uri_template'),
  };
}

sub _bundle_ref_path { ('$defs', shift->_flat_ref_name(@_)) }

*_resolve_object                    = \&JSON::Validator::Schema::Draft6::_resolve_object;
*_validate_number_max               = \&JSON::Validator::Schema::Draft6::_validate_number_max;
*_validate_number_min               = \&JSON::Validator::Schema::Draft6::_validate_number_min;
*_validate_type_array               = \&JSON::Validator::Schema::Draft6::_validate_type_array;
*_validate_type_array_contains      = \&JSON::Validator::Schema::Draft6::_validate_type_array_contains;
*_validate_type_array_items         = \&JSON::Validator::Schema::Draft4::_validate_type_array_items;
*_validate_type_array_min_max       = \&JSON::Validator::Schema::Draft4::_validate_type_array_min_max;
*_validate_type_array_unique        = \&JSON::Validator::Schema::Draft4::_validate_type_array_unique;
*_validate_type_object              = \&JSON::Validator::Schema::Draft6::_validate_type_object;
*_validate_type_object_dependencies = \&JSON::Validator::Schema::Draft4::_validate_type_object_dependencies;
*_validate_type_object_min_max      = \&JSON::Validator::Schema::Draft4::_validate_type_object_min_max;
*_validate_type_object_names        = \&JSON::Validator::Schema::Draft6::_validate_type_object_names;
*_validate_type_object_properties   = \&JSON::Validator::Schema::Draft4::_validate_type_object_properties;

1;

=encoding utf8

=head1 NAME

JSON::Validator::Schema::Draft7 - JSON-Schema Draft 7

=head1 SYNOPSIS

See L<JSON::Validator::Schema/SYNOPSIS>.

=head1 DESCRIPTION

This class represents
L<https://json-schema.org/specification-links.html#draft-7>.

=head1 ATTRIBUTES

=head2 specification

  my $str = $schema->specification;

Defaults to "L<http://json-schema.org/draft-07/schema#>".

=head1 SEE ALSO

L<JSON::Validator::Schema>.

=cut
