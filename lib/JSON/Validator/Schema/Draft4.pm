package JSON::Validator::Schema::Draft4;
use Mojo::Base 'JSON::Validator::Schema';

use JSON::Validator::Util qw(E data_checksum data_type is_type json_pointer);
use List::Util 'uniq';

has id => sub {
  my $data = shift->data;
  return is_type($data, 'HASH') ? $data->{id} || '' : '';
};

has specification => 'http://json-schema.org/draft-04/schema#';

sub _build_formats {
  return {
    'date-time' => JSON::Validator::Formats->can('check_date_time'),
    'email'     => JSON::Validator::Formats->can('check_email'),
    'hostname'  => JSON::Validator::Formats->can('check_hostname'),
    'ipv4'      => JSON::Validator::Formats->can('check_ipv4'),
    'ipv6'      => JSON::Validator::Formats->can('check_ipv6'),
    'regex'     => JSON::Validator::Formats->can('check_regex'),
    'uri'       => JSON::Validator::Formats->can('check_uri'),
  };
}

sub _validate_number_max {
  my ($self, $value, $state, $expected) = @_;
  return unless defined(my $cmp_with = $state->{schema}{maximum});

  my $key = $state->{schema}{exclusiveMaximum} ? 'ex_maximum' : 'maximum';
  return if $key eq 'maximum' ? $value <= $cmp_with : $value < $cmp_with;
  return E $state->{path}, [$expected => $key => $value, $cmp_with];
}

sub _validate_number_min {
  my ($self, $value, $state, $expected) = @_;
  return unless defined(my $cmp_with = $state->{schema}{minimum});

  my $key = $state->{schema}{exclusiveMinimum} ? 'ex_minimum' : 'minimum';
  return if $key eq 'minimum' ? $value >= $cmp_with : $value > $cmp_with;
  return E $state->{path}, [$expected => $key => $value, $cmp_with];
}

sub _validate_type_array {
  my ($self, $data, $state) = @_;
  return E $state->{path}, [array => type => data_type $data] if ref $data ne 'ARRAY';

  return (
    $self->_validate_type_array_min_max($_[1], $state),
    $self->_validate_type_array_unique($_[1], $state),
    $self->_validate_type_array_items($_[1], $state),
  );
}

sub _validate_type_array_items {
  my ($self, $data, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};
  my @errors;

  if (ref $schema->{items} eq 'ARRAY') {
    my $additional_items = $schema->{additionalItems} // {};
    my @rules            = @{$schema->{items}};

    if ($additional_items) {
      push @rules, $additional_items while @rules < @$data;
    }

    if (@rules >= @$data) {
      for my $i (0 .. @$data - 1) {
        push @errors, $self->_validate($data->[$i], $self->_state($state, path => "$path/$i", schema => $rules[$i]));
      }
    }
    elsif (!$additional_items) {
      push @errors, E $path, [array => additionalItems => int(@$data), int(@rules)];
    }
  }
  elsif (exists $schema->{items}) {
    for my $i (0 .. @$data - 1) {
      push @errors,
        $self->_validate($data->[$i], $self->_state($state, path => "$path/$i", schema => $schema->{items}));
    }
  }

  return @errors;
}

sub _validate_type_array_min_max {
  my ($self, $data, $state) = @_;
  my @errors;

  if (defined $state->{schema}{minItems} and $state->{schema}{minItems} > @$data) {
    push @errors, E $state->{path}, [array => minItems => int(@$data), $state->{schema}{minItems}];
  }
  if (defined $state->{schema}{maxItems} and $state->{schema}{maxItems} < @$data) {
    push @errors, E $state->{path}, [array => maxItems => int(@$data), $state->{schema}{maxItems}];
  }

  return @errors;
}

sub _validate_type_array_unique {
  my ($self, $data, $state) = @_;
  return unless $state->{schema}{uniqueItems};

  my (@errors, %uniq);
  for (@$data) {
    next if !$uniq{data_checksum($_)}++;
    push @errors, E $state->{path}, [array => 'uniqueItems'];
    last;
  }

  return @errors;
}

sub _validate_type_object {
  my ($self, $data, $state) = @_;
  return E $state->{path}, [object => type => data_type $data] if ref $data ne 'HASH';

  return (
    $self->_validate_type_object_min_max($_[1], $state),
    $self->_validate_type_object_dependencies($_[1], $state),
    $self->_validate_type_object_properties($_[1], $state),
  );
}

sub _validate_type_object_min_max {
  my ($self, $data, $state) = @_;

  my @errors;
  my @dkeys = keys %$data;
  if (defined $state->{schema}{maxProperties} and $state->{schema}{maxProperties} < @dkeys) {
    push @errors, E $state->{path}, [object => maxProperties => int(@dkeys), $state->{schema}{maxProperties}];
  }
  if (defined $state->{schema}{minProperties} and $state->{schema}{minProperties} > @dkeys) {
    push @errors, E $state->{path}, [object => minProperties => int(@dkeys), $state->{schema}{minProperties}];
  }

  return @errors;
}

sub _validate_type_object_dependencies {
  my ($self, $data, $state) = @_;
  my $dependencies = $state->{schema}{dependencies} || {};
  my @errors;

  for my $k (keys %$dependencies) {
    next if not exists $data->{$k};
    if (ref $dependencies->{$k} eq 'ARRAY') {
      push @errors,
        map { E json_pointer($state->{path}, $_), [object => dependencies => $k] }
        grep { !exists $data->{$_} } @{$dependencies->{$k}};
    }
    else {
      push @errors, $self->_validate($data, $self->_state($state, schema => $dependencies->{$k}));
    }
  }

  return @errors;
}

sub _validate_type_object_properties {
  my ($self, $data, $state) = @_;
  my ($path, $schema, @errors, %rules) = @$state{qw(path schema)};
  my @dkeys = keys %$data;

  for my $k (keys %{$schema->{properties} || {}}) {
    my $r = $schema->{properties}{$k};
    push @{$rules{$k}}, $r;
    if ($self->{coerce}{defaults} and ref $r eq 'HASH' and exists $r->{default} and !exists $data->{$k}) {
      $data->{$k} = $r->{default};
    }
  }

  for my $p (keys %{$schema->{patternProperties} || {}}) {
    my $r = $schema->{patternProperties}{$p};
    push @{$rules{$_}}, $r for grep { $_ =~ /$p/ } @dkeys;
  }

  my $additional = exists $schema->{additionalProperties} ? $schema->{additionalProperties} : {};
  if ($additional) {
    $additional = {} unless is_type $additional, 'HASH';
    $rules{$_} ||= [$additional] for @dkeys;
  }
  elsif (my @k = grep { !$rules{$_} } @dkeys) {
    local $" = ', ';
    return E $path, [object => additionalProperties => join ', ', sort @k];
  }

  for my $k (uniq @{$schema->{required} || []}) {
    next if exists $data->{$k};
    push @errors, E json_pointer($path, $k), [object => 'required'];
    delete $rules{$k};
  }

  for my $k (keys %rules) {
    for my $r (@{$rules{$k}}) {
      next unless exists $data->{$k};
      my $s2 = $self->_state($state, path => json_pointer($path, $k), schema => $r);
      my @e  = $self->_validate($data->{$k}, $s2);
      push @errors, @e;
      next if @e or !is_type $r, 'HASH';
      push @errors, $self->_validate_type_enum($data->{$k}, $s2)  if $r->{enum};
      push @errors, $self->_validate_type_const($data->{$k}, $s2) if $r->{const};
    }
  }

  return @errors;
}

1;

=encoding utf8

=head1 NAME

JSON::Validator::Schema::Draft4 - JSON-Schema Draft 4

=head1 SYNOPSIS

See L<JSON::Validator::Schema/SYNOPSIS>.

=head1 DESCRIPTION

This class represents
L<https://json-schema.org/specification-links.html#draft-4>.

=head1 ATTRIBUTES

=head2 specification

  my $str    = $schema->specification;
  my $schema = $schema->specification($str);

Defaults to "L<http://json-schema.org/draft-04/schema#>".

=head1 SEE ALSO

L<JSON::Validator::Schema>.

=cut
