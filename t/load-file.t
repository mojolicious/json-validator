use Mojo::Base -strict;
use JSON::Validator;
use Test::More;

my $file = Mojo::File::path(qw(t spec person.json))->to_abs;
my $spec = Mojo::URL->new->scheme('file')->host('')->path(join '/', @$file);
my $jv   = JSON::Validator->new;
my $id   = File::Spec->case_tolerant ? lc $spec : $spec->to_string;

note $spec->to_string;
ok eval { $jv->schema($file) }, 'loaded from file://' or diag $@;
isa_ok $jv->schema, 'JSON::Validator::Schema';
is $jv->schema->get('/title'), 'Example Schema', 'got example schema';
is $jv->schema->id, $id, 'schema id';
is_deeply [sort keys %{$jv->store->schemas}], [$jv->schema->id], 'schemas in store';

ok eval { $jv->schema($spec->to_string) }, 'loaded from file:// again' or diag $@;
is $jv->schema->id, $id, 'schema id again';
is_deeply [sort keys %{$jv->store->schemas}], [$jv->schema->id], 'schemas in store again';

eval { $jv->load_and_validate_schema('no-such-file.json') };
like $@, qr{Unable to load schema "no-such-file\.json"}, 'cannot load no-such-file.json';

eval { $jv->load_and_validate_schema('/no-such-file.json') };
like $@, qr{Unable to load schema "/no-such-file\.json"},
  'avoid loading from app, when $ua->server->app is not present';

done_testing;
