use Mojo::Base -strict;
use Mojo::JSON 'false';
use Mojo::Util 'md5_sum';
use JSON::Validator;
use JSON::Validator::Util qw(E data_checksum data_type negotiate_content_type schema_type prefix_errors json_pointer);
use JSON::Validator::Util qw(is_bool is_num is_type);
use Test::More;

my $e = E '/path/x', 'some error';
is "$e", '/path/x: some error', 'E';

is data_type('string'), 'string', 'data_type string';
is data_type(4.2),      'number', 'data_type number';
is data_type(42, [{type => 'integer'}]), 'integer', 'data_type integer';
is data_type([]), 'array', 'data_type array';
is data_type(bless {}, 'other'), 'other', 'data_type other';
is data_type(false), 'boolean', 'data_type boolean';
is data_type(undef), 'null', 'data_type null';
is data_type($e), 'JSON::Validator::Error', 'data_type JSON::Validator::Error';

my $v = JSON::Validator->new;
ok is_type($v, 'JSON::Validator'), 'is_type JSON::Validator';
ok is_type($v, 'Mojo::Base'),      'is_type Mojo::Base';
ok is_type($v, 'HASH'),            'is_type HASH';
ok is_type([], 'ARRAY'),           'is_type ARRAY';
ok is_type({}, 'HASH'),            'is_type HASH';

ok is_num(4.2),  'is_num 4.2';
ok is_num(42),   'is_num 42';
ok !is_num('2'), 'is_num 2';

ok is_bool(false), 'is_bool';
ok !is_bool(0), 'is_bool';

is json_pointer(qw(foo bar)),    'foo/bar',      'json_pointer foo bar';
is json_pointer(qw(f/oo bar)),   'f/oo/bar',     'json_pointer f/oo bar';
is json_pointer(qw(f/oo ~b/ar)), 'f/oo/~0b~1ar', 'json_pointer f/oo ~b/ar';

my $yikes = E {path => '/path/100/y', message => 'yikes'};
is_deeply(
  [map {"$_"} prefix_errors 'allOf', [2, $e], [5, $yikes]],
  ['/path/x: /allOf/2 some error',   '/path/100/y: /allOf/5 yikes'],
  'prefix_errors',
);

is negotiate_content_type([]), '', 'accepts nothing';
is negotiate_content_type(['multipart/form-data'], 'multipart/form-data; boundary=mgkBX'), 'multipart/form-data',
  'form-data boundary';
is negotiate_content_type(['application/json'], 'application/json;charset=UTF-8'), 'application/json', 'charset';
is negotiate_content_type(['application/json']), '', 'header missing';
is negotiate_content_type(['application/json', 'text/plain'], 'application/json'), 'application/json', 'exact match';
is negotiate_content_type(['application/json', 'text/*'], 'text/plain'),           'text/*',           'closest accept';
is negotiate_content_type(
  ['text/plain', 'application/xml'],
  'text/html;text/plain;q=0.2,application/xml;q=0.9,*/*;q=0.8'
  ),
  'application/xml', 'exact match with weight';

is schema_type({type => 'integer'}), 'integer', 'schema_type integer';
is schema_type({additionalProperties => {}}), 'object', 'schema_type object';
is schema_type({additionalProperties => {}}, {}), 'object', 'schema_type object';
is schema_type({additionalProperties => {}}, []), '',       'schema_type not object';
is schema_type({items      => {}}), 'array', 'schema_type array';
is schema_type({items      => {}}, {}), '', 'schema_type not array';
is schema_type({minLength  => 4}),       'string', 'schema_type string';
is schema_type({multipleOf => 2}),       'number', 'schema_type number';
is schema_type({const      => 42}),      'const',  'schema_type const';
is schema_type({cannot     => 'guess'}), '',       'schema_type no idea';

subtest 'data_checksum with Sereal::Encoder' => sub {
  plan skip_all => 'Sereal::Encoder 4.00+ not installed' unless JSON::Validator::Util->SEREAL_SUPPORT;

  my $d_hash   = {foo => {}, bar => {}};
  my $d_hash2  = {bar => {}, foo => {}};
  my $d_undef  = {foo => undef};
  my $d_obj    = {foo => JSON::Validator::Error->new};
  my $d_array  = ['foo', 'bar'];
  my $d_array2 = ['bar', 'foo'];

  isnt data_checksum($d_array), data_checksum($d_array2), 'data_checksum array';
  is data_checksum($d_hash),    data_checksum($d_hash2),  'data_checksum hash field order';
  isnt data_checksum($d_hash),  data_checksum($d_undef),  'data_checksum hash not undef';
  isnt data_checksum($d_hash),  data_checksum($d_obj),    'data_checksum hash not object';
  isnt data_checksum($d_obj),   data_checksum($d_undef),  'data_checksum object not undef';
  isnt data_checksum(3.14), md5_sum(3.15),         'data_checksum numeric';
  is data_checksum(3.14),   data_checksum('3.14'), 'data_checksum numeric like string';
};

done_testing;
