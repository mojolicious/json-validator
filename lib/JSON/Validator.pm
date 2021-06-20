package JSON::Validator;
use Mojo::Base -base;

use Carp qw(confess);
use JSON::Validator::Ref;
use JSON::Validator::Store;
use JSON::Validator::Util qw(E data_checksum is_bool is_type);
use Mojo::File qw(path);
use Mojo::URL;
use Mojo::Util qw(monkey_patch sha1_sum);
use Scalar::Util qw(blessed refaddr);

our $VERSION = '4.20';

our %SCHEMAS = (
  'http://json-schema.org/draft-04/schema#'             => '+Draft4',
  'http://json-schema.org/draft-06/schema#'             => '+Draft6',
  'http://json-schema.org/draft-07/schema#'             => '+Draft7',
  'https://json-schema.org/draft/2019-09/schema'        => '+Draft201909',
  'http://swagger.io/v2/schema.json'                    => '+OpenAPIv2',
  'https://spec.openapis.org/oas/3.0/schema/2019-04-02' => '+OpenAPIv3',
);

has formats                   => sub { require JSON::Validator::Schema; JSON::Validator::Schema->_build_formats };
has recursive_data_protection => 1;

has store => sub {
  my $self = shift;
  my %attrs;
  $attrs{$_} = delete $self->{$_} for grep { $self->{$_} } qw(cache_paths ua);
  return JSON::Validator::Store->new(%attrs);
};

# store proxy attributes
for my $method (qw(cache_paths ua)) {
  Mojo::Util::monkey_patch(__PACKAGE__, $method => sub { shift->store->$method(@_) });
}

sub bundle {
  my ($self, $args) = @_;

  my $get_data  = $self->can('data') ? 'data' : 'schema';
  my $schema    = $self->_new_schema($args->{schema} || $self->$get_data);
  my $schema_id = $schema->id;
  my @topics    = ([$schema->data, my $bundle = {}]);                        # ([$from, $to], ...);

  my $cloner = sub {
    my $from      = shift;
    my $from_type = ref $from;
    my $tied      = $from_type eq 'HASH' && tied %$from;

    unless ($tied) {
      my $to = $from_type eq 'ARRAY' ? [] : $from_type eq 'HASH' ? {} : $from;
      push @topics, [$from, $to] if $from_type;
      return $to;
    }

    # Traverse all $ref
    while (my $tmp = tied %{$tied->schema}) { $tied = $tmp }

    return $from if !$args->{schema} and $tied->fqn =~ m!^\Q$schema_id\E\#!;

    my $path = $self->_definitions_path($bundle, $tied);
    unless ($self->{bundled_refs}{$tied->fqn}++) {
      push @topics, [_node($schema->data, $path, 1, 0) || {}, _node($bundle, $path, 1, 1)];
      push @topics, [$tied->schema, _node($bundle, $path, 0, 1)];
    }

    $path = join '/', '#', @$path;
    tie my %ref, 'JSON::Validator::Ref', $tied->schema, $path;
    return \%ref;
  };

  local $self->{bundled_refs} = {};

  while (@topics) {
    my ($from, $to) = @{shift @topics};
    if (ref $from eq 'ARRAY') {
      for (my $i = 0; $i < @$from; $i++) {
        $to->[$i] = $cloner->($from->[$i]);
      }
    }
    elsif (ref $from eq 'HASH') {
      for my $key (keys %$from) {
        $to->{$key} //= $cloner->($from->{$key});
      }
    }
  }

  return $bundle;
}

sub coerce {
  my $self = shift;
  return $self->{coerce} ||= {} unless defined(my $what = shift);

  state $short = {bool => 'booleans', def => 'defaults', num => 'numbers', str => 'strings'};
  $what                                 = {map { ($_ => 1) } split /,/, $what} unless ref $what;
  $self->{coerce}                       = {};
  $self->{coerce}{($short->{$_} || $_)} = $what->{$_} for keys %$what;

  return $self;
}

sub get { shift->schema->get(@_) }

sub load_and_validate_schema {
  my ($self, $schema, $args) = @_;

  delete $self->{schema};
  my $schema_obj = $self->_new_schema($schema, %$args);
  confess join "\n", "Invalid JSON specification", (ref $schema eq 'HASH' ? Mojo::Util::dumper($schema) : $schema),
    map {"- $_"} @{$schema_obj->errors}
    if @{$schema_obj->errors};

  $self->{schema} = $schema_obj;
  return $self;
}

sub new {
  my $self = shift->SUPER::new(@_);
  $self->coerce($self->{coerce}) if defined $self->{coerce};
  return $self;
}

sub schema {
  my $self = shift;
  return $self->{schema} unless @_;
  $self->{schema} = $self->_new_schema(shift);
  return $self;
}

sub validate {
  my ($self, $data, $schema) = @_;
  return +(defined $schema ? $self->_new_schema($schema) : $self->schema)->validate($_[1]);
}

sub _definitions_path {
  my ($self, $bundle, $ref) = @_;
  my $path = $self->_definitions_path_for_ref($ref);

  # No need to rewrite, if it already has a nice name
  my $node   = _node($bundle, $path, 2, 0);
  my $prefix = join '/', @$path;
  if ($ref->fqn =~ m!#/$prefix/([^/]+)$!) {
    my $key = $1;

    if ( $self->{bundled_refs}{$ref->fqn}
      or !$node
      or !$node->{$key}
      or data_checksum($ref->schema) eq data_checksum($node->{$key}))
    {
      return [@$path, $key];
    }
  }

  # Generate definitions key based on filename
  my $fqn = Mojo::URL->new($ref->fqn);
  my $key = $fqn->fragment;
  if ($fqn->scheme and $fqn->scheme eq 'file') {
    $key = join '-', map { s!^\W+!!; $_ } grep {$_} path($fqn->path)->basename, $key,
      substr(sha1_sum($fqn->path), 0, 10);
  }

  # Fallback or nicer path name
  $key =~ s![^\w-]!_!g;
  return [@$path, $key];
}

sub _definitions_path_for_ref { ['definitions'] }

sub _find_and_resolve_refs {
  my ($self, $base_url, $schema) = @_;
  my %root = is_type($schema, 'HASH') ? %$schema : ();

  my ($id_key, @topics, @refs, %seen) = ($self->_id_key, [$base_url, $schema]);
  while (@topics) {
    my ($base_url, $topic) = @{shift @topics};

    if (is_type $topic, 'ARRAY') {
      push @topics, map { [$base_url, $_] } @$topic;
    }
    elsif (is_type $topic, 'HASH') {
      next if $seen{refaddr($topic)}++;

      my $base_url = $base_url;    # do not change the global $base_url
      if ($topic->{$id_key} and !ref $topic->{$id_key}) {
        my $id = Mojo::URL->new($topic->{$id_key});
        $id = $id->to_abs($base_url) unless $id->is_abs;
        $self->store->add($id => $topic);
        $base_url = $id;
      }

      my $has_ref = $topic->{'$ref'} && !ref $topic->{'$ref'} && !tied %$topic ? 1 : 0;
      push @refs, [$base_url, $topic] if $has_ref;

      for my $key (keys %$topic) {
        next unless ref $topic->{$key};
        next if $has_ref and $key eq '$ref';
        push @topics, [$base_url, $topic->{$key}];
      }
    }
  }

  while (@refs) {
    my ($base_url, $topic) = @{shift @refs};
    next if is_bool $topic;
    next if !$topic->{'$ref'} or ref $topic->{'$ref'};
    my $base = Mojo::URL->new($base_url || $base_url)->fragment(undef);
    my ($other, $ref_url, $fqn) = $self->_resolve_ref($topic->{'$ref'}, $base, \%root);
    tie %$topic, 'JSON::Validator::Ref', $other, "$ref_url", "$fqn";
    push @refs, [$other, $fqn];
  }
}

sub _id_key { $_[0]->schema ? $_[0]->schema->_id_key : 'id' }

sub _new_schema {
  my ($self, $source, %attrs) = @_;
  return $source if blessed $source and $source->can('specification');

  # Compat with load_and_validate_schema()
  $attrs{specification} = delete $attrs{schema} if $attrs{schema};

  my $loadable
    = (blessed $source && ($source->can('scheme') || $source->isa('Mojo::File')))
    || ($source !~ /\n/ && -f $source)
    || (!ref $source && $source =~ /^\w/);

  my $store  = $self->store;
  my $schema = $loadable ? $store->get($store->load($source)) : $source;

  $attrs{recursive_data_protection} //= $self->recursive_data_protection;

  $attrs{coerce}  ||= $self->{coerce}  if $self->{coerce};
  $attrs{formats} ||= $self->{formats} if $self->{formats};
  $attrs{specification} = $schema->{'$schema'}
    if !$attrs{specification}
    and is_type $schema, 'HASH'
    and $schema->{'$schema'};
  $attrs{store} = $store;

  # Detect openapiv2 and v3 schemas by content, since no "$schema" is present
  my $spec = $attrs{specification} || $schema;
  if (ref $spec eq 'HASH' and $spec->{paths}) {
    if ($spec->{swagger} and $spec->{swagger} eq '2.0') {
      $spec = 'http://swagger.io/v2/schema.json';
    }
    elsif ($spec->{openapi} and $spec->{openapi} =~ m!^3\.0\.\d+$!) {
      $spec = 'https://spec.openapis.org/oas/3.0/schema/2019-04-02';
    }
  }

  my $schema_class = $spec && $SCHEMAS{$spec} || 'JSON::Validator::Schema';
  $schema_class =~ s!^\+(.+)$!JSON::Validator::Schema::$1!;
  confess "Could not load $schema_class: $@" unless $schema_class->can('new') or eval "require $schema_class;1";
  return $schema_class->new($source, %attrs);
}

sub _node {
  my ($node, $path, $offset, $create) = @_;

  my $n = 0;
  while ($path->[$n]) {
    $node->{$path->[$n]} ||= {} if $create;
    return undef unless $node = $node->{$path->[$n]};
    last if (++$n) + $offset >= @$path;
  }

  return $node;
}

sub _register_root_schema {
  my ($self, $id, $schema) = @_;
  confess "Root schema cannot have a fragment in the 'id'. ($id)" if $id =~ /\#./;
  confess "Root schema cannot have a relative 'id'. ($id)" unless $id =~ /^\w+:/ or -e $id or $id =~ m!^/!;
}

# _resolve() method is used to convert all "id" into absolute URLs and
# resolve all the $ref's that we find inside JSON Schema specification.
sub _resolve {
  my ($self, $schema, $nested) = @_;
  return $schema if is_bool $schema;

  my ($id_key, $id, $cached_id, $resolved) = ($self->_id_key);
  if (ref $schema eq 'HASH') {
    $id        = $schema->{$id_key} // '';
    $cached_id = $self->store->exists($id);
    $resolved  = $cached_id ? $self->store->get($cached_id) : $schema;
  }
  else {
    $cached_id = $self->store->exists($id);
    $id        = $cached_id // $self->store->load($schema);
    $resolved  = $self->store->get($id);
    $id        = $resolved->{$id_key} if is_type($resolved, 'HASH') and $resolved->{$id_key};
  }

  $cached_id //= '';
  $id = Mojo::URL->new("$id");
  $self->_register_root_schema($id => $resolved) if !$nested and "$id";
  $self->store->add($id => $resolved)            if "$id"    and "$id" ne $cached_id;
  $self->_find_and_resolve_refs($id => $resolved) unless $cached_id;

  return $resolved;
}

sub _resolve_ref {
  my ($self, $ref_url, $base_url, $schema) = @_;
  $ref_url = "#$ref_url" if $ref_url =~ m!^/!;

  my $fqn     = Mojo::URL->new($ref_url);
  my $pointer = $fqn->fragment;
  my $other;

  $fqn = $fqn->to_abs($base_url) if "$base_url";
  $other //= $self->store->get($fqn);
  $other //= $self->store->get($fqn->clone->fragment(undef));
  $other //= $self->_resolve($fqn->clone->fragment(undef), 1) if $fqn->is_abs && $fqn ne $base_url;
  $other //= $schema;

  if (defined $pointer and $pointer =~ m!^/!) {
    $other = Mojo::JSON::Pointer->new($other)->get($pointer);
    confess qq[Possibly a typo in schema? Could not find "$pointer" in "$fqn" ($ref_url)] unless defined $other;
  }

  $fqn->fragment($pointer // '');
  return $other, $ref_url, $fqn;
}

1;

=encoding utf8

=head1 NAME

JSON::Validator - Validate data against a JSON schema

=head1 SYNOPSIS

=head2 Using a schema object

L<JSON::Validator::Schema> or any of the sub classes can be used instead of
L<JSON::Validator>.

=head2 Basics

  use JSON::Validator;
  my $jv = JSON::Validator->new;

  # Define a schema - http://json-schema.org/learn/miscellaneous-examples.html
  # You can also load schema from disk or web
  $jv->schema({
    type       => "object",
    required   => ["firstName", "lastName"],
    properties => {
      firstName => {type => "string"},
      lastName  => {type => "string"},
      age       => {type => "integer", minimum => 0, description => "Age in years"}
    }
  });

  # Validate your data
  my @errors = $jv->validate({firstName => "Jan Henning", lastName => "Thorsen", age => -42});

  # Do something if any errors was found
  die "@errors" if @errors;

=head2 Using joi

  # Use joi() to build the schema
  use JSON::Validator::Joi 'joi';

  $jv->schema(joi->object->props({
    firstName => joi->string->required,
    lastName  => joi->string->required,
    age       => joi->integer->min(0),
  }));

  # joi() can also validate directly
  my @errors = joi(
    {firstName => "Jan Henning", lastName => "Thorsen", age => -42},
    joi->object->props({
      firstName => joi->string->required,
      lastName  => joi->string->required,
      age       => joi->integer->min(0),
    }),
  );

=head1 DESCRIPTION

L<JSON::Validator> is a data structure validation library based around
L<JSON Schema|https://json-schema.org/>. This module can be used directly with
a JSON schema or you can use the elegant DSL schema-builder
L<JSON::Validator::Joi> to define the schema programmatically.

=head2 Supported schema formats

L<JSON::Validator> can load JSON schemas in multiple formats: Plain perl data
structured (as shown in L</SYNOPSIS>), JSON or YAML. The JSON parsing is done
with L<Mojo::JSON>, while YAML files requires L<YAML::PP> or L<YAML::XS>.

=head2 Resources

Here are some resources that are related to JSON schemas and validation:

=over 4

=item * L<http://json-schema.org/documentation.html>

=item * L<https://json-schema.org/understanding-json-schema/index.html>

=item * L<https://github.com/json-schema/json-schema/>

=back

=head2 Bundled specifications

This module comes with some JSON specifications bundled, so your application
don't have to fetch those from the web. These specifications should be up to
date, but please submit an issue if they are not.

Files referenced to an URL will automatically be cached if the first element in
L</cache_paths> is a writable directory. Note that the cache headers for the
remote assets are B<not> honored, so you will manually need to remove any
cached file, should you need to refresh them.

To download and cache an online asset, do this:

  JSON_VALIDATOR_CACHE_PATH=/some/writable/directory perl myapp.pl

Here is the list of the bundled specifications:

=over 2

=item * JSON schema, draft 4, 6, 7, 2019-09.

Web page: L<http://json-schema.org>

C<$ref>: L<http://json-schema.org/draft-04/schema#>,
L<http://json-schema.org/draft-06/schema#>,
L<http://json-schema.org/draft-07/schema#>.

=item * JSON schema for JSONPatch files

Web page: L<http://jsonpatch.com>

C<$ref>: L<http://json.schemastore.org/json-patch#>

=item * Swagger / OpenAPI specification, version 2

Web page: L<https://openapis.org>

C<$ref>: L<http://swagger.io/v2/schema.json#>

=item * OpenAPI specification, version 3

Web page: L<https://openapis.org>

C<$ref>: L<https://spec.openapis.org/oas/3.0/schema/2019-04-02|https://github.com/OAI/OpenAPI-Specification/blob/master/schemas/v3.0/schema.json>

This specification is still EXPERIMENTAL.

=item * Swagger Petstore

This is used for unit tests, and should not be relied on by external users.

=back

=head2 Optional modules

=over 2

=item * Sereal::Encoder

Installing L<Sereal::Encoder> v4.00 (or later) will make
L<JSON::Validator::Util/data_checksum> significantly faster. This function is
used both when parsing schemas and validating data.

=item * Format validators

See the documentation in L<JSON::Validator::Formats> for other optional modules
to do validation of specific "format", such as "hostname", "ipv4" and others.

=back

=head1 ERROR OBJECT

The method L</validate> returns a list of L<JSON::Validator::Error> objects
when the input data violates the L</schema>.

=head1 ATTRIBUTES

=head2 cache_paths

Proxy attribute for L<JSON::Validator::Store/cache_paths>.

=head2 formats

  my $hash_ref = $jv->formats;
  my $jv = $jv->formats(\%hash);

Holds a hash-ref, where the keys are supported JSON type "formats", and
the values holds a code block which can validate a given format. A code
block should return C<undef> on success and an error string on error:

  sub { return defined $_[0] && $_[0] eq "42" ? undef : "Not the answer." };

See L<JSON::Validator::Formats> for a list of supported formats.

=head2 recursive_data_protection

  my $jv = $jv->recursive_data_protection($bool);
  my $bool = $jv->recursive_data_protection;

Recursive data protection is active by default, however it can be deactivated
by assigning a false value to the L</recursive_data_protection> attribute.

Recursive data protection can have a noticeable impact on memory usage when
validating large data structures. If you are encountering issues with memory
and you can guarantee that you do not have any loops in your data structure
then deactivating the recursive data protection may help.

This attribute is EXPERIMENTAL and may change in a future release.

B<Disclaimer: Use at your own risk, if you have any doubt then don't use it>

=head2 store

  $store = $jv->store;

Holds a L<JSON::Validator::Store> object that caches the retrieved schemas.
This object can be shared amongst different schema objects to prevent
a schema from having to be downloaded again.

=head2 ua

Proxy attribute for L<JSON::Validator::Store/ua>.

=head1 METHODS

=head2 bundle

  # These two lines does the same
  my $schema = $jv->bundle({schema => $jv->schema->data});
  my $schema = $jv->bundle;

  # Will only bundle a section of the schema
  my $schema = $jv->bundle({schema => $jv->schema->get("/properties/person/age")});

Used to create a new schema, where there are no "$ref" pointing to external
resources. This means that all the "$ref" that are found, will be moved into
the "definitions" key, in the returned C<$schema>.

=head2 coerce

  my $jv       = $jv->coerce('bool,def,num,str');
  my $jv       = $jv->coerce('booleans,defaults,numbers,strings');
  my $hash_ref = $jv->coerce;

Set the given type to coerce. Before enabling coercion this module is very
strict when it comes to validating types. Example: The string C<"1"> is not
the same as the number C<1>, unless you have "numbers" coercion enabled.

=over 2

=item * booleans

Will convert what looks can be interpreted as a boolean (that is, an actual
numeric C<1> or C<0>, and the strings "true" and "false") to a
L<JSON::PP::Boolean> object. Note that "foo" is not considered a true value and
will fail the validation.

=item * defaults

Will copy the default value defined in the schema, into the input structure,
if the input value is non-existing.

Note that support for "default" is currently EXPERIMENTAL, and enabling this
might be changed in future versions.

=item * numbers

Will convert strings that looks like numbers, into true numbers. This works for
both the "integer" and "number" types.

=item * strings

Will convert a number into a string. This works for the "string" type.

=back

=head2 get

  my $sub_schema = $jv->get("/x/y");
  my $sub_schema = $jv->get(["x", "y"]);

Extract value from L</schema> identified by the given JSON Pointer. Will at the
same time resolve C<$ref> if found. Example:

  $jv->schema({x => {'$ref' => '#/y'}, y => {'type' => 'string'}});
  $jv->schema->get('/x')           == {'$ref' => '#/y'}
  $jv->schema->get('/x')->{'$ref'} == '#/y'
  $jv->get('/x')                   == {type => 'string'}

The argument can also be an array-ref with the different parts of the pointer
as each elements.

=head2 new

  $jv = JSON::Validator->new(%attributes);
  $jv = JSON::Validator->new(\%attributes);

Creates a new L<JSON::Validate> object.

=head2 load_and_validate_schema

  my $jv = $jv->load_and_validate_schema($schema, \%args);

Will load and validate C<$schema> against the OpenAPI specification. C<$schema>
can be anything L<JSON::Validator/schema> accepts. The expanded specification
will be stored in L<JSON::Validator/schema> on success. See
L<JSON::Validator/schema> for the different version of C<$url> that can be
accepted.

C<%args> can be used to further instruct the validation process:

=over 2

=item * schema

Defaults to "http://json-schema.org/draft-04/schema#", but can be any
structured that can be used to validate C<$schema>.

=back

=head2 schema

  my $jv     = $jv->schema($json_or_yaml_string);
  my $jv     = $jv->schema($url);
  my $jv     = $jv->schema(\%schema);
  my $jv     = $jv->schema(JSON::Validator::Joi->new);
  my $jv     = $jv->schema(JSON::Validator::Schema->new);
  my $schema = $jv->schema;

Used to set a schema from either a data structure or a URL.

C<$schema> will be a L<JSON::Validator::Schema> object when loaded,
and C<undef> by default.

The C<$url> can take many forms, but needs to point to a text file in the
JSON or YAML format.

=over 4

=item * file://...

A file on disk. Note that it is required to use the "file" scheme if you want
to reference absolute paths on your file system.

=item * http://... or https://...

A web resource will be fetched using the L<Mojo::UserAgent>, stored in L</ua>.

=item * data://Some::Module/spec.json

Will load a given "spec.json" file from C<Some::Module> using
L<JSON::Validator::Util/data_section>.

=item * data:///spec.json

A "data" URL without a module name will use the current package and search up
the call/inheritance tree.

=item * Any other URL

An URL (without a recognized scheme) will be treated as a path to a file on
disk. If the file could not be found on disk and the path starts with "/", then
the will be loaded from the app defined in L</ua>. Something like this:

  $jv->ua->server->app(MyMojoApp->new);
  $jv->ua->get('/any/other/url.json');

=back

=head2 validate

  my @errors = $jv->validate($data);

Validates C<$data> against L</schema>. C<@errors> will contain validation error
objects, in a predictable order (specifically, alphanumerically sorted by the
error objects' C<path>) or be an empty list on success.

See L</ERROR OBJECT> for details.

=head1 SEE ALSO

=over 2

=item * L<JSON::Validator::Formats>

L<JSON::Validator::Formats> contains utility functions for validating data
types. Could be useful for validating data without loading a schema.

=item * L<JSON::Validator::Schema>

L<JSON::Validator::Schema> is the base class for
L<JSON::Validator::Schema::Draft4>, L<JSON::Validator::Schema::Draft6>
L<JSON::Validator::Schema::Draft7>, L<JSON::Validator::Schema::Draft201909>,
L<JSON::Validator::Schema::OpenAPIv2> or L<JSON::Validator::Schema::OpenAPIv3>.

=item * L<JSON::Validator::Util>

L<JSON::Validator::Util> contains many useful function when working with
schemas.

=item * L<Mojolicious::Plugin::OpenAPI>

L<Mojolicious::Plugin::OpenAPI> is a plugin for L<Mojolicious> that utilize
L<JSON::Validator> and the L<OpenAPI specification|https://www.openapis.org/>
to build routes with input and output validation.

=back

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014-2021, Jan Henning Thorsen

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

Daniel Böhmer - C<post@daniel-boehmer.de>

Ed J - C<mohawk2@users.noreply.github.com>

Karen Etheridge - C<ether@cpan.org>

Kevin Goess - C<cpan@goess.org>

Martin Renvoize - C<martin.renvoize@gmail.com>

=cut
