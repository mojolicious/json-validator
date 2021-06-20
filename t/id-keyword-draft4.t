use Mojo::Base -strict;
use JSON::Validator;
use Mojo::JSON 'encode_json';
use Test::Mojo;
use Test::More;

my ($base_url, $jv, $t, @e);

use Mojolicious::Lite;
get '/invalid-fragment'     => [format => ['json']] => 'invalid-fragment';
get '/invalid-relative'     => [format => ['json']] => 'invalid-relative';
get '/relative-to-the-root' => [format => ['json']] => 'relative-to-the-root';

$t  = Test::Mojo->new;
$jv = JSON::Validator->new(ua => $t->ua);
$t->get_ok('/relative-to-the-root.json')->status_is(200);

$base_url = $t->tx->req->url->to_abs->path('/');
like $base_url, qr{^http}, 'got base_url to web server';
is $jv->_id_key, 'id', 'default id_key';

eval { $jv->load_and_validate_schema("${base_url}relative-to-the-root.json") };
ok !$@, "${base_url}relative-to-the-root.json" or diag $@;
isa_ok $jv->schema, 'JSON::Validator::Schema::Draft4';

my $schema = $jv->schema;
is $schema->moniker,       'draft04',                                 'moniker';
is $schema->specification, 'http://json-schema.org/draft-04/schema#', 'specification';
is $schema->get('/id'),               'http://example.com/relative-to-the-root.json', 'get /id';
is $schema->get('/definitions/B/id'), 'b.json',                                       'id /definitions/B/id';
is $schema->get('/definitions/B/definitions/X/id'), '#bx',          'id /definitions/B/definitions/X/id';
is $schema->get('/definitions/B/definitions/Y/id'), 't/inner.json', 'id /definitions/B/definitions/Y/id';
is $schema->get('/definitions/C/definitions/X/id'), 'urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f',
  'id /definitions/C/definitions/X/id';
is $schema->get('/definitions/C/definitions/Y/id'), '#cy', 'id /definitions/C/definitions/Y/id';

my $r1 = $schema->get('/definitions/R1');
is encode_json($r1), '{"$ref":"b.json#bx"}', 'R1 encode_json';
$r1 = tied %$r1;
is $r1->ref, 'b.json#bx',                    'R1 ref';
is $r1->fqn, 'http://example.com/b.json#bx', 'R1 fqn';
is_deeply $r1->schema, {id => '#bx'}, 'R1 schema';

eval { $jv->load_and_validate_schema("${base_url}invalid-fragment.json") };
like $@, qr{cannot have a fragment}, 'Root id cannot have a fragment' or diag $@;

eval { $jv->load_and_validate_schema("${base_url}invalid-relative.json") };
like $@, qr{cannot have a relative}, 'Root id cannot be relative' or diag $@;

done_testing;

__DATA__
@@ invalid-fragment.json.ep
{"id": "http://example.com/invalid-fragment.json#cannot_be_here"}
@@ invalid-relative.json.ep
{"id": "whatever"}
@@ relative-to-the-root.json.ep
{
  "id": "http://example.com/relative-to-the-root.json",
  "$schema": "http://json-schema.org/draft-04/schema#",
  "definitions": {
    "A": { "id": "#a" },
    "B": {
      "id": "b.json",
      "definitions": {
        "X": { "id": "#bx" },
        "Y": { "id": "t/inner.json" }
      }
    },
    "C": {
      "id": "c.json",
      "definitions": {
        "X": { "id": "urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f" },
        "Y": { "id": "#cy" }
      }
    },
    "R1": { "$ref": "b.json#bx" },
    "R2": { "$ref": "#a" },
    "R3": { "$ref": "urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f" }
  }
}
