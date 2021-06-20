use Mojo::Base -strict;
use JSON::Validator;
use JSON::Validator::Schema::Draft7;
use Mojo::File 'path';
use Test::More;

my $workdir = path(__FILE__)->to_abs->dirname;
my $jv      = JSON::Validator->new;

subtest 'Run multiple times to make sure _reset() works' => sub {
  for my $n (1 .. 3) {
    my $bundled = $jv->schema({
      surname     => {'$ref' => '#/definitions/name'},
      age         => {'$ref' => 'b.json#/definitions/years'},
      definitions => {name   => {type => 'string'}},
      B           => {id     => 'b.json', definitions => {years => {type => 'integer'}}},
    })->bundle;
    ok $bundled->{definitions}{name}, "[$n] definitions/name still in definitions";
    is $bundled->{definitions}{name}{type},  'string',  "[$n] definitions/name/type still in definitions";
    is $bundled->{definitions}{years}{type}, 'integer', "[$n] added to definitions";
    isnt $bundled->{age},   $jv->schema->get('/age'),     "[$n] new age ref";
    is $bundled->{surname}, $jv->schema->get('/surname'), "[$n] same surname ref";
    is $bundled->{age}{'$ref'},     '#/definitions/years', "[$n] age \$ref point to /definitions/years";
    is $bundled->{surname}{'$ref'}, '#/definitions/name',  "[$n] surname \$ref point to /definitions/name";
  }
};

subtest 'check bundled structure' => sub {
  is $jv->get([qw(surname type)]), 'string', 'get /surname/$ref';
  is $jv->get('/surname/type'), 'string', 'get /surname/type';
  is $jv->get('/surname/$ref'), undef,    'get /surname/$ref';
  is $jv->schema->get('/surname/type'), 'string',             'schema get /surname/type';
  is $jv->schema->get('/surname/$ref'), '#/definitions/name', 'schema get /surname/$ref';

  my $bundled = $jv->schema('data://main/bundled.json')->bundle;
  is_deeply [sort keys %{$bundled->{definitions}}], ['objtype'], 'no dup definitions';
};

subtest 'definitions in disk spec' => sub {
  for my $path (
    ['test-definitions-key.json'],
    ['with-deep-mixed-ref.json'],
    ['with-deep-mixed-ref.json'],
    [File::Spec->updir, 'spec', 'with-deep-mixed-ref.json'],
    )
  {
    my $file = path $workdir, 'spec', @$path;

    my @expected = qw(age_json-SHA height unit_json-SHA weight_json-SHA);
    $expected[0] = 'age_json-type-SHA' if $path->[0] eq 'test-definitions-key.json';

    my $bundled = $jv->schema($file)->bundle;
    is_deeply [sort map { s!-[a-z0-9]{10}$!-SHA!; $_ } keys %{$bundled->{definitions}}], \@expected,
      "right definitions in disk spec @$path"
      or diag join ', ', sort keys %{$bundled->{definitions}};
  }
};

subtest 'ensure filenames with funny characters not mangled by Mojo::URL' => sub {
  my $file3   = path $workdir, 'spec', 'space bundle.json';
  my $bundled = eval { $jv->schema($file3)->bundle };
  is $@, '', 'loaded absolute filename with space';
  is $bundled->{properties}{age}{description}, 'Age in years', 'right definitions in disk spec'
    or diag explain $bundled;
};

subtest 'extract subset of schema' => sub {
  my $bundled = $jv->schema('data://main/bundled.json')->bundle({schema => $jv->get([qw(paths /withdots get)])});
  is_deeply(
    $bundled,
    {
      definitions => {objtype => {properties => {propname => {type => 'string'}}, type => 'object'}},
      responses   => {200     => {schema     => {'$ref'   => '#/definitions/objtype'}}}
    },
    'subset of schema was bundled'
  ) or diag explain $bundled;
};

subtest 'no leaking path' => sub {
  my $bundled = $jv->schema('data://main/bundled.json')->bundle({schema => $jv->get([qw(paths /withdots get)])});
  my $ref_name_prefix = $workdir;
  $ref_name_prefix =~ s![^\w-]!_!g;
  $jv->schema(path $workdir, 'spec', 'bundle-no-leaking-filename.json');
  my @definitions = keys %{$bundled->{definitions}};
  ok @definitions, 'definitions are present';
  is_deeply [grep { 0 == index $_, $ref_name_prefix } @definitions], [], 'no leaking of path';
};

done_testing;

__DATA__
@@ bundled.json
{
  "definitions": {
    "objtype": {
      "type": "object",
      "properties": {"propname": {"type": "string"}}
    }
  },
  "paths": {
    "/withdots": {
      "get": {
        "responses": {
          "200": {"schema": {"$ref": "#/definitions/objtype"}}
        }
      }
    }
  }
}
