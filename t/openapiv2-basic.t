use Mojo::Base -strict;
use JSON::Validator::Schema::OpenAPIv2;
use Test::Deep;
use Test::More;

my $cwd    = Mojo::File->new(__FILE__)->dirname;
my $schema = JSON::Validator::Schema::OpenAPIv2->new;
my ($body, @errors);

subtest 'basic' => sub {
  is $schema->specification, 'http://swagger.io/v2/schema.json', 'specification';
  is_deeply $schema->coerce, {booleans => 1, numbers => 1, strings => 1}, 'default coercion';

  eval {
    my $s = JSON::Validator->new->schema('data://main/spec-resolve-refs.json')->schema;
    is $s->get([qw(paths /user get responses 200 schema type)]), 'object', 'resolved "User"';
    1;
  } or do {
    diag $@;
    ok 0, 'Could not resolve "User"';
  };

  $schema = JSON::Validator->new->schema($cwd->child(qw(spec v2-petstore.json)))->schema->resolve;
  isa_ok $schema, 'JSON::Validator::Schema::OpenAPIv2';

  is_deeply(
    $schema->routes->to_array,
    [
      {method => 'get',  operation_id => 'listPets',    path => '/pets'},
      {method => 'post', operation_id => 'createPets',  path => '/pets'},
      {method => 'get',  operation_id => 'showPetById', path => '/pets/{petId}'},
    ],
    'routes'
  );

  is_deeply $schema->errors, [], 'errors';
};

subtest base_url => sub {
  is $schema->base_url, 'http://petstore.swagger.io/v1', 'get';
  is $schema->base_url('https://api.example.com:8080/api'), $schema, 'set url';
  is_deeply $schema->get('/schemes'), ['https'], 'schemes changed';
  is $schema->get('/host'),           'api.example.com:8080', 'host changed';
  is $schema->get('/basePath'),       '/api',                 'basePath changed';

  is $schema->base_url(Mojo::URL->new('//api2.example.com')), $schema, 'set without scheme';
  is_deeply $schema->get('/schemes'), ['https'], 'schemes unchanged';
  is $schema->get('/host'),           'api2.example.com', 'host changed';
  is $schema->get('/basePath'),       '/',                'basePath changed';

  is $schema->base_url(Mojo::URL->new('/v1')), $schema, 'set path';
  is $schema->base_url->to_string, 'https://api2.example.com/v1', 'get';

  my $schema_with_port = JSON::Validator->new->schema($cwd->child(qw(spec bundlecheck.json)))->schema->resolve;
  is $schema_with_port->base_url->host, 'localhost', 'host';
  is $schema_with_port->base_url->port, 3000,        'port';
};

subtest 'validate schema' => sub {
  @errors = @{JSON::Validator->new->schema({swagger => '2.0', paths => {}})->schema->errors};
  is "@errors", '/info: Missing property.', 'invalid schema';
};

subtest 'parameters_for_request' => sub {
  is $schema->parameters_for_request([GET => '/pets/nope']), undef, 'no such path';
  cmp_deeply $schema->parameters_for_request([GET => '/pets']), [superhashof({in => 'query', name => 'limit'})],
    'parameters_for_request inside path';
  cmp_deeply $schema->parameters_for_request([post => '/pets']),
    [superhashof({in => 'body', name => 'body', accepts => ['application/json']})], 'parameters_for_request for body';
  cmp_deeply $schema->parameters_for_request([get => '/pets/{petId}']), [superhashof({in => 'path', name => 'petId'})],
    'parameters_for_request inside method';
};

subtest 'parameters_for_response' => sub {
  is $schema->parameters_for_response([GET => '/pets/nope']), undef, 'no such path';
  cmp_deeply $schema->parameters_for_response([GET => '/pets']),
    [
    superhashof({in => 'header', name => 'x-next'}),
    superhashof({in => 'body',   name => 'body', accepts => ['application/json']}),
    ],
    'parameters_for_request inside path and default response code';
  cmp_deeply $schema->parameters_for_response([GET => '/pets', 404]),
    [superhashof({in => 'body', name => 'body', accepts => ['application/json']})], 'default response';
};

subtest 'validate_request' => sub {
  @errors = $schema->validate_request([get => '/pets'], {query => {limit => 10, foo => '42'}});
  is "@errors", '', 'limit ok, even as string';

  @errors = $schema->validate_request([get => '/pets'], {query => {limit => 'foo'}});
  is "@errors", '/limit: Expected integer - got string.', 'limit failed';

  $body   = {exists => 0};
  @errors = $schema->validate_request([POST => '/pets'], {body => \&body});
  is "@errors", '/body: Missing property.', 'default content type, but missing body';
  is_deeply $body, {exists => 0, in => 'body', name => 'body', valid => 0}, 'input was mutated';

  $body   = {exists => 1, value => {name => 'kitty'}};
  @errors = $schema->validate_request([POST => '/pets'], {body => \&body});
  is "@errors", '/body/id: Missing property.', 'missing id in body';

  $body   = {exists => 1, value => {id => 42, name => 'kitty'}};
  @errors = $schema->validate_request([POST => '/pets'], {body => \&body});
  is "@errors", '', 'valid request body';
  is_deeply $body,
    {
    content_type => 'application/json',
    exists       => 1,
    in           => 'body',
    name         => 'body',
    valid        => 1,
    value        => $body->{value}
    },
    'input was mutated';
};

subtest 'validate_response' => sub {
  $body   = {exists => 1, value => {id => 42, name => 'kitty'}};
  @errors = $schema->validate_response([POST => '/pets', 201], {});
  is "@errors", '', 'valid response body 201';

  $body   = {exists => 1, value => {code => 42}};
  @errors = $schema->validate_response([post => '/pets', 200], {body => \&body});
  is "@errors", '/body/message: Missing property.', 'valid response body default';
};

subtest 'validate_response - accept' => sub {
  $body   = {accept => 'text/plain'};
  @errors = $schema->validate_response([get => '/pets'], {body => \&body});
  is "@errors", '/header/Accept: Expected application/json - got text/plain.', 'invalid accept';
  is_deeply $body, {accept => 'text/plain', content_type => '', in => 'body', name => 'body', valid => 0},
    'failed to negotiate content type';

  $body   = {accept => 'application/*'};
  @errors = $schema->validate_response([get => '/pets'], {body => \&body});
  is "@errors", '', 'valid accept';
  is_deeply $body,
    {accept => 'application/*', content_type => 'application/json', in => 'body', name => 'body', valid => 1},
    'negotiated content type';
};

subtest 'validate_response - content_type' => sub {
  $body   = {content_type => 'text/plain'};
  @errors = $schema->validate_response([get => '/pets'], {body => \&body});
  is "@errors", '/body: Expected application/json - got text/plain.', 'invalid content_type';
  is_deeply $body, {content_type => 'text/plain', in => 'body', name => 'body', valid => 0},
    'failed to negotiate content type';

  $body   = {content_type => 'application/json'};
  @errors = $schema->validate_response([get => '/pets'], {body => \&body});
  is "@errors", '', 'valid content_type';
  is_deeply $body,
    {content_type => 'application/json', content_type => 'application/json', in => 'body', name => 'body', valid => 1},
    'negotiated content type';
};

subtest add_default_response => sub {
  $schema = JSON::Validator->new->schema($cwd->child(qw(spec v2-petstore.json)))->schema->resolve;
  ok !$schema->get('/definitions/DefaultResponse'), 'default response missing';
  ok !$schema->get([paths => '/petss', 'get', 'responses', '400']), 'default response missing for 400';
  $schema->add_default_response;
  ok $schema->get('/definitions/DefaultResponse'), 'default response added';

  for my $status (400, 401, 404, 500, 501) {
    ok $schema->get([paths => '/pets', 'get', 'responses', $status]), "default response for $status";
  }

  delete $schema->{errors};
  is_deeply $schema->errors, [], 'errors';
};

done_testing;

sub body {$body}

__DATA__
@@ spec-resolve-refs.json
{
  "swagger": "2.0",
  "info": {"version": "", "title": "Test non standard refs"},
  "basePath": "/api",
  "paths": {
    "/user": {
      "get": {
        "responses": {
          "200": { "description": "ok", "schema": { "$ref": "User" } }
        }
      }
    }
  },
  "definitions": {
    "User": {
      "type": "object",
      "properties": {}
    }
  }
}
