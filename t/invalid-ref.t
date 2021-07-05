use Mojo::Base -strict;
use JSON::Validator;
use Mojo::File 'path';
use Test::More;

eval { JSON::Validator->new->schema('data://main/spec.json') };
like $@, qr{Unable to resolve .*/definitions/Pet"}, 'missing definition';

my $workdir = path(__FILE__)->dirname;
eval { JSON::Validator->new->schema(path($workdir, 'spec', 'missing-ref.json')); };

ok $@, 'loading missing ref failed';
like $@, qr{Unable to load schema.*missing\.json}, 'error message' unless $^O eq 'MSWin32';

done_testing;

__DATA__
@@ spec.json
{
  "schema": {
    "type": "array",
    "items": { "$ref": "#/definitions/Pet" }
  }
}
