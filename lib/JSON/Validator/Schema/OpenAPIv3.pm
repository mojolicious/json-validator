package JSON::Validator::Schema::OpenAPIv3;
use Mojo::Base 'JSON::Validator::Schema::Draft201909';

use JSON::Validator::Schema::OpenAPIv2;
use JSON::Validator::Util qw(E data_type negotiate_content_type schema_type);
use Mojo::JSON qw(false true);
use Mojo::Path;
use Mojo::Util qw(monkey_patch);

has moniker       => 'openapiv3';
has specification => 'https://spec.openapis.org/oas/3.0/schema/2019-04-02';

# some methods are shared with OpenAPIv2
monkey_patch __PACKAGE__,
  $_ => JSON::Validator::Schema::OpenAPIv2->can($_)
  for qw(coerce routes validate_request validate_response),
  qw(_coerce_arrays _coerce_default_value _find_all_nodes _params_for_add_default_response _prefix_error_path _validate_request_or_response);

sub add_default_response {
  my ($self, $params) = ($_[0], shift->_params_for_add_default_response(@_));

  my $responses = $self->data->{components}{schemas} ||= {};
  my $ref       = $responses->{$params->{name}}      ||= $params->{schema};
  my %schema    = ('$ref' => "#/components/schemas/$params->{name}");
  tie %schema, 'JSON::Validator::Ref', $ref, $schema{'$ref'}, $schema{'$ref'};

  for my $route ($self->routes->each) {
    my $op = $self->get([paths => @$route{qw(path method)}]);
    $op->{responses}{$_}
      ||= {description => $params->{description}, content => {'application/json' => {schema => \%schema}}}
      for @{$params->{status}};
  }

  return $self;
}

sub base_url {
  my ($self, $url) = @_;

  # Get
  return Mojo::URL->new($self->get('/servers/0/url') || '') unless $url;

  # Set
  $url = Mojo::URL->new($url)->to_abs($self->base_url);
  $self->data->{servers}[0]{url} = $url->to_string;
  return $self;
}

sub new {
  my $self = shift->SUPER::new(@_);
  $self->coerce;    # make sure this attribute is built
  $self;
}

sub parameters_for_request {
  my $self = shift;
  my ($method, $path) = (lc $_[0][0], $_[0][1]);

  my $cache_key = "parameters_for_request:$method:$path";
  return $self->{cache}{$cache_key} if $self->{cache}{$cache_key};
  return undef unless $self->get([paths => $path, $method]);

  my @parameters = map {@$_} $self->_find_all_nodes([paths => $path, $method], 'parameters');
  for my $param (@parameters) {
    $param->{type} ||= schema_type($param->{schema});
  }

  if (my $request_body = $self->get([paths => $path, $method, 'requestBody'])) {
    my @accepts = sort keys %{$request_body->{content} || {}};
    push @parameters,
      {
      accepts  => \@accepts,
      content  => $request_body->{content},
      in       => 'body',
      name     => 'body',
      required => $request_body->{required},
      };
  }

  return $self->{cache}{$cache_key} = \@parameters;
}

sub parameters_for_response {
  my $self = shift;
  my ($method, $path, $status) = (lc $_[0][0], $_[0][1], $_[0][2] || 200);

  $status ||= 200;
  my $cache_key = "parameters_for_response:$method:$path:$status";
  return $self->{cache}{$cache_key} if $self->{cache}{$cache_key};

  my $responses = $self->get([paths => $path, $method, 'responses']);
  my $response  = $responses->{$status} || $responses->{default};
  return undef unless $response;

  my @parameters;
  if (my $headers = $response->{headers}) {
    push @parameters, map { +{%{$headers->{$_}}, in => 'header', name => $_} } sort keys %$headers;
  }

  if (my @accepts = sort keys %{$response->{content} || {}}) {
    push @parameters, {accepts => \@accepts, content => $response->{content}, in => 'body', name => 'body'};
  }

  return $self->{cache}{$cache_key} = \@parameters;
}

sub _build_formats {

  # TODO: Figure out if this is the correct list
  return {
    'binary'                => sub {undef},
    'byte'                  => JSON::Validator::Formats->can('check_byte'),
    'date'                  => JSON::Validator::Formats->can('check_date'),
    'date-time'             => JSON::Validator::Formats->can('check_date_time'),
    'double'                => JSON::Validator::Formats->can('check_double'),
    'duration'              => JSON::Validator::Formats->can('check_duration'),
    'email'                 => JSON::Validator::Formats->can('check_email'),
    'float'                 => JSON::Validator::Formats->can('check_float'),
    'hostname'              => JSON::Validator::Formats->can('check_hostname'),
    'idn-email'             => JSON::Validator::Formats->can('check_idn_email'),
    'idn-hostname'          => JSON::Validator::Formats->can('check_idn_hostname'),
    'int32'                 => JSON::Validator::Formats->can('check_int32'),
    'int64'                 => JSON::Validator::Formats->can('check_int64'),
    'ipv4'                  => JSON::Validator::Formats->can('check_ipv4'),
    'ipv6'                  => JSON::Validator::Formats->can('check_ipv6'),
    'iri'                   => JSON::Validator::Formats->can('check_iri'),
    'iri-reference'         => JSON::Validator::Formats->can('check_iri_reference'),
    'json-pointer'          => JSON::Validator::Formats->can('check_json_pointer'),
    'password'              => sub {undef},
    'regex'                 => JSON::Validator::Formats->can('check_regex'),
    'relative-json-pointer' => JSON::Validator::Formats->can('check_relative_json_pointer'),
    'time'                  => JSON::Validator::Formats->can('check_time'),
    'uri'                   => JSON::Validator::Formats->can('check_uri'),
    'uri-reference'         => JSON::Validator::Formats->can('check_uri_reference'),
    'uri-template'          => JSON::Validator::Formats->can('check_uri_template'),
    'uuid'                  => JSON::Validator::Formats->can('check_uuid'),
  };
}

sub _coerce_parameter_format {
  my ($self, $val, $param) = @_;
  return unless $val->{exists};

  state $in_style = {cookie => 'form', header => 'simple', path => 'simple', query => 'form'};
  $param->{style} = $in_style->{$param->{in}} unless $param->{style};
  return $self->_coerce_parameter_style_object_deep($val, $param) if $param->{style} eq 'deepObject';

  my $schema_type = schema_type $param;
  return $self->_coerce_parameter_style_array($val, $param)  if $schema_type eq 'array';
  return $self->_coerce_parameter_style_object($val, $param) if $schema_type eq 'object';
}

sub _coerce_parameter_style_array {
  my ($self, $val, $param) = @_;
  my $style   = $param->{style};
  my $explode = $param->{explode} // $param->{style} eq 'form' ? true : false;
  my $re;

  if ($style =~ m!^(form|pipeDelimited|spaceDelimited|simple)$!) {
    return $val->{value} = ref $val->{value} eq 'ARRAY' ? $val->{value} : [$val->{value}] if $explode;
    $re = $style eq 'pipeDelimited' ? qr{\|} : $style eq 'spaceDelimited' ? $re = qr{[ ]} : qr{,};
  }
  elsif ($style eq 'label') {
    $re = qr{\.};
    $re = qr{,} if $val->{value} =~ s/^$re// and !$explode;
  }
  elsif ($style eq 'matrix') {
    $re = qr{;\Q$param->{name}\E=};
    $re = qr{,} if $val->{value} =~ s/^$re// and !$explode;
  }

  return $val->{value} = [_split($re, $val->{value})];
}

sub _coerce_parameter_style_object {
  my ($self, $val, $param) = @_;
  my $style   = $param->{style};
  my $explode = $param->{explode} // (grep { $style eq $_ } qw(cookie query)) ? 1 : 0;

  if ($explode) {
    return if $style eq 'form';
    state $style_re = {label => qr{\.}, matrix => qr{;}, simple => qr{,}};
    return unless my $re = $style_re->{$style};
    return if $style eq 'matrix' && $val->{value} !~ s/^;//;
    return if $style eq 'label'  && $val->{value} !~ s/^\.//;
    my $params = Mojo::Parameters->new;
    $params->append(Mojo::Parameters->new($_)) for _split($re, $val->{value});
    return $val->{value} = $params->to_hash;
  }
  else {
    state $style_re = {
      form           => qr{,},
      label          => qr{\.},
      matrix         => qr{,},
      pipeDelimited  => qr{\|},
      simple         => qr{,},
      spaceDelimited => qr{[ ]},
    };
    return unless my $re = $style_re->{$style};
    return if $style eq 'matrix' && $val->{value} !~ s/^;\Q$param->{name}\E=//;
    return if $style eq 'label'  && $val->{value} !~ s/^\.//;
    return $val->{value} = Mojo::Parameters->new->pairs([_split($re, $val->{value})])->to_hash;
  }
}

sub _coerce_parameter_style_object_deep {
  my ($self, $val, $param) = @_;
  my %res;

  for my $k (keys %{$val->{value}}) {
    next unless $k =~ /^\Q$param->{name}\E\[(.*)\]/;

    my @path   = $k =~ m!\[([^]]*)\]!g;
    my $values = ref $val->{value}{$k} eq 'ARRAY' ? $val->{value}{$k} : [$val->{value}{$k}];
    my $node   = \%res;
    while (defined(my $p = shift @path)) {
      if (@path) {
        my $next = $path[0] =~ m!^(|\d+)$! ? [] : {};
        $node = ref $node eq 'ARRAY' ? ($node->[$p] ||= $next) : ($node->{$p} ||= $next);
      }
      elsif ($p eq '') {
        @$node = @$values;
      }
      elsif ($p =~ /^\d+$/) {
        $node->[$p] = $values->[0];
      }
      else {
        $node->{$p} = @$values > 1 ? $values : $values->[0];
      }
    }
  }

  return $val->{value}  = \%res if %res;
  return $val->{exists} = 0;
}

sub _definitions_path_for_ref {
  my ($self, $ref) = @_;
  my $path = Mojo::Path->new($ref->fqn =~ m!^.*#/(components/.+)$!)->to_dir->parts;
  return $path->[0] ? $path : ['definitions'];
}

sub _get_parameter_value {
  my ($self, $param, $get) = @_;
  my $schema_type = schema_type $param;
  my $name        = $param->{name};
  $name = undef if $schema_type eq 'object' && $param->{explode} && ($param->{style} || '') =~ m!^(form|deepObject)$!;

  my $val = $get->{$param->{in}}->($name, $param);
  @$val{qw(in name)} = (@$param{qw(in name)});
  return $val;
}

sub _split {
  my ($re, $val) = @_;
  $val = @$val ? $val->[-1] : '' if ref $val;
  return split /$re/, $val;
}

sub _to_list { ref $_[0] eq 'ARRAY' ? @{$_[0]} : $_[0] ? ($_[0]) : () }

sub _validate_body {
  my ($self, $direction, $val, $param) = @_;

  if ($val->{accept}) {
    $val->{content_type} = negotiate_content_type($param->{accepts}, $val->{accept});
    $val->{valid}        = $val->{content_type} ? 1 : 0;
    return E "/header/Accept", [join(', ', @{$param->{accepts}}), type => $val->{accept}] unless $val->{valid};
  }
  if (@{$param->{accepts}} and $val->{content_type}) {
    my $negotiated = negotiate_content_type($param->{accepts}, $val->{content_type});
    $val->{valid} = $negotiated ? 1 : 0;
    return E "/$param->{name}", [join(', ', @{$param->{accepts}}) => type => $val->{content_type}] unless $negotiated;
  }
  if ($param->{required} and !$val->{exists}) {
    $val->{valid} = 0;
    return E "/$param->{name}", [qw(object required)];
  }
  if ($val->{exists}) {
    local $self->{"validate_$direction"} = 1;
    $val->{content_type} //= $param->{accepts}[0];
    my @errors = map { $_->path(_prefix_error_path($param->{name}, $_->path)); $_ }
      $self->validate($val->{value}, $param->{content}{$val->{content_type}}{schema});
    $val->{valid} = @errors ? 0 : 1;
    return @errors;
  }

  return;
}

sub _validate_type_array {
  my $self = shift;
  return $_[1]->{schema}{nullable} && !defined $_[0] ? () : $self->SUPER::_validate_type_array(@_);
}

sub _validate_type_boolean {
  my $self = shift;
  return $_[1]->{schema}{nullable} && !defined $_[0] ? () : $self->SUPER::_validate_type_boolean(@_);
}

sub _validate_type_integer {
  my $self = shift;
  return $_[1]->{schema}{nullable} && !defined $_[0] ? () : $self->SUPER::_validate_type_integer(@_);
}

sub _validate_type_number {
  my $self = shift;
  return $_[1]->{schema}{nullable} && !defined $_[0] ? () : $self->SUPER::_validate_type_number(@_);
}

sub _validate_type_object {
  my ($self, $data, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};
  return if $schema->{nullable} && !defined $data;
  return E $path, [object => type => data_type $data] if ref $data ne 'HASH';
  return shift->SUPER::_validate_type_object(@_) unless $self->{validate_request} or $self->{validate_response};

  # TODO: Support external URLs in "mapping"
  my $discriminator = $schema->{discriminator};
  if (ref $discriminator eq 'HASH' and $discriminator->{propertyName} and !$state->{inside_discriminator}) {
    my ($name, $mapping) = @$discriminator{qw(propertyName mapping)};
    return E $path, "Discriminator $name has no value."          unless my $map_name = $data->{$name};
    return E $path, "No definition for discriminator $map_name." unless my $url      = $mapping->{$map_name};
    return E $path, "TODO: Not yet supported: $url"              unless $url =~ s!^#!!;
    return $self->_validate($data, $self->_state($state, inside_discriminator => 1, schema => $self->get($url)));
  }

  return $self->{validate_request}
    ? $self->_validate_type_object_request($_[1], $state)
    : $self->_validate_type_object_response($_[1], $state);
}

sub _validate_type_object_request {
  my ($self, $data, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};

  my (@errors, %ro);
  for my $name (keys %{$schema->{properties} || {}}) {
    next unless $schema->{properties}{$name}{readOnly};
    push @errors, E "$path/$name", "Read-only." if exists $data->{$name};
    $ro{$name} = 1;
  }

  local $schema->{required} = [grep { !$ro{$_} } @{$schema->{required} || []}];

  return (
    @errors,
    $self->_validate_type_object_min_max($_[1], $state),
    $self->_validate_type_object_dependencies($_[1], $state),
    $self->_validate_type_object_properties($_[1], $state),
  );
}

sub _validate_type_object_response {
  my ($self, $data, $state) = @_;
  my ($path, $schema) = @$state{qw(path schema)};

  my (@errors, %rw);
  for my $name (keys %{$schema->{properties} || {}}) {
    next unless $schema->{properties}{$name}{writeOnly};
    push @errors, E "$path/$name", "Write-only." if exists $data->{$name};
    $rw{$name} = 1;
  }

  local $schema->{required} = [grep { !$rw{$_} } @{$schema->{required} || []}];

  return (
    @errors,
    $self->_validate_type_object_min_max($_[1], $state),
    $self->_validate_type_object_dependencies($_[1], $state),
    $self->_validate_type_object_properties($_[1], $state),
  );
}

sub _validate_type_string {
  my $self = shift;
  return $_[1]->{schema}{nullable} && !defined $_[0] ? () : $self->SUPER::_validate_type_string(@_);
}

1;

=encoding utf8

=head1 NAME

JSON::Validator::Schema::OpenAPIv3 - OpenAPI version 3

=head1 SYNOPSIS

See L<JSON::Validator::Schema::OpenAPIv2/SYNOPSIS>.

=head1 DESCRIPTION

This class represents L<https://spec.openapis.org/oas/3.0/schema/2019-04-02>.

=head1 ATTRIBUTES

=head2 moniker

  $str    = $schema->moniker;
  $schema = $schema->moniker("openapiv3");

Used to get/set the moniker for the given schema. Default value is "openapiv3".

=head2 specification

  my $str    = $schema->specification;
  my $schema = $schema->specification($str);

Defaults to "L<https://spec.openapis.org/oas/3.0/schema/2019-04-02>".

=head1 METHODS

=head2 add_default_response

  $schema = $schema->add_default_response(\%params);

See L<JSON::Validator::Schema::OpenAPIv2/add_default_response> for details.

=head2 base_url

  $url = $schema->base_url;
  $schema = $schema->base_url($url);

Can get or set the default URL for this schema. C<$url> can be either a
L<Mojo::URL> object or a plain string.

This method will read or write "/servers/0/url" in L</data>.

=head2 coerce

  my $schema   = $schema->coerce({booleans => 1, numbers => 1, strings => 1});
  my $hash_ref = $schema->coerce;

Coercion is enabled by default, since headers, path parts, query parameters,
... are in most cases strings.

=head2 new

  $schema = JSON::Validator::Schema::OpenAPIv2->new(\%attrs);
  $schema = JSON::Validator::Schema::OpenAPIv2->new;

Same as L<JSON::Validator::Schema/new>, but will also build L/coerce>.

=head2 parameters_for_request

  $parameters = $schema->parameters_for_request([$method, $path]);

Finds all the request parameters defined in the schema, including inherited
parameters. Returns C<undef> if the C<$path> and C<$method> cannot be found.

Example return value:

  [
    {in => "query", name => "q"},
    {in => "body", name => "body", accepts => ["application/json"]},
  ]

The return value MUST not be mutated.

=head2 parameters_for_response

  $array_ref = $schema->parameters_for_response([$method, $path, $status]);

Finds the response parameters defined in the schema. Returns C<undef> if the
C<$path>, C<$method> and C<$status> cannot be found. Will default to the
"default" response definition if C<$status> could not be found and "default"
exists.

Example return value:

  [
    {in => "header", name => "X-Foo"},
    {in => "body", name => "body", accepts => ["application/json"]},
  ]

The return value MUST not be mutated.

=head2 routes

  $collection = $schema->routes;

Shares the same interface as L<JSON::Validator::Schema::OpenAPIv2/routes>.

=head2 validate_request

  @errors = $schema->validate_request([$method, $path], \%req);

Shares the same interface as L<JSON::Validator::Schema::OpenAPIv2/validate_request>.

=head2 validate_response

  @errors = $schema->validate_response([$method, $path], \%req);

Shares the same interface as L<JSON::Validator::Schema::OpenAPIv2/validate_response>.

=head1 SEE ALSO

L<JSON::Validator::Schema>, L<JSON::Validator::Schema::OpenAPIv2> and and
L<JSON::Validator>.

=cut
