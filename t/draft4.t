use lib '.';
use t::Helper;
use JSON::Validator::Schema::Draft4;

t::Helper->schema(JSON::Validator::Schema::Draft4->new);

t::Helper->test(number => qw(basic maximum minimum));
t::Helper->test(array  => qw(basic items additional_items min_max unique));
t::Helper->test(object => qw(basic properties));
t::Helper->test(object => qw(additional_properties pattern_properties min_max));

subtest 'exclusiveMaximum' => sub {
  schema_validate_ok 2.4, {exclusiveMaximum => true, maximum => 2.4}, E('/', '2.4 >= maximum(2.4)');
};

subtest 'exclusiveMinimum' => sub {
  schema_validate_ok 0, {exclusiveMaximum => true, maximum => 0}, E('/', '0 >= maximum(0)');
};

subtest 'bundle' => sub {
  my $bundle = JSON::Validator::Schema::Draft4->new('data://main/spec.json')->bundle;
  is $bundle->data->{properties}{name}{'$ref'},              '#/definitions/defs_json-name', 'bundle ref';
  is $bundle->data->{'definitions'}{'defs_json-name'}{type}, 'string', 'bundled spec under definitions';
};

done_testing;

__DATA__
@@ spec.json
{"type":"object","properties":{"name":{"$ref":"data://main/defs.json#/name"}}}
@@ defs.json
{"name":{"type":"string"}}
