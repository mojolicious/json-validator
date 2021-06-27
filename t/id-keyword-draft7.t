use Mojo::Base -strict;
use JSON::Validator;
use Test::Mojo;
use Test::More;

my ($base_url, $jv, $t, @e);

use Mojolicious::Lite;
get '/person'           => [format => ['json']] => 'person';
get '/invalid-relative' => [format => ['json']] => 'invalid-relative';

$t  = Test::Mojo->new;
$jv = JSON::Validator->new(ua => $t->ua);

eval {
  $t->get_ok('/person.json')->status_is(200);
  $base_url = $t->tx->req->url->to_abs->path('/');
  $jv->load_and_validate_schema("${base_url}person.json", {schema => 'http://json-schema.org/draft-07/schema#'});
};
ok !$@, "${base_url}schema.json" or diag $@;
isa_ok $jv->schema, 'JSON::Validator::Schema::Draft7';

is $jv->schema->id,            'http://example.com/person.json',          'schema id';
is $jv->schema->moniker,       'draft07',                                 'moniker';
is $jv->schema->specification, 'http://json-schema.org/draft-07/schema#', 'schema specification';

eval { $jv->load_and_validate_schema("${base_url}invalid-relative.json") };
like $@, qr{Relative URL not allowed}, 'Root id cannot be relative' or diag $@;

done_testing;

__DATA__
@@ invalid-relative.json.ep
{"$id": "whatever", "$schema": "http://json-schema.org/draft-07/schema#"}
@@ person.json.ep
{
  "$id": "http://example.com/person.json",
  "definitions": {
    "Person": {
      "type": "object",
      "properties": {
        "firstName": { "type": "string" }
      }
    }
  }
}
