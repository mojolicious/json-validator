use Mojo::Base -strict;
use Test::More;
use JSON::Validator::URI;

subtest 'url https' => sub {
  my $url = JSON::Validator::URI->new('https://foo.com');
  is $url->scheme, 'https',   'scheme';
  is $url->host,   'foo.com', 'host';
  is $url->nid,    undef,     'nid';
  is $url->nss,    undef,     'nss';
};

subtest 'urn uuid' => sub {
  my $urn = JSON::Validator::URI->new('urn:uuid:ee564b8a-7a87-4125-8c96-e9f123d6766f');
  is $urn->host,     undef,                                  'host';
  is $urn->scheme,   'urn',                                  'scheme';
  is $urn->nid,      'uuid',                                 'nid';
  is $urn->nss,      'ee564b8a-7a87-4125-8c96-e9f123d6766f', 'nss';
  is $urn->fragment, undef,                                  'fragment';
};

subtest 'urn jv' => sub {
  my $urn = JSON::Validator::URI->new('urn:jv:draft4-4242#foo');
  ok $urn->is_abs,   'is_abs';
  is $urn->host,     undef,         'host';
  is $urn->scheme,   'urn',         'scheme';
  is $urn->nid,      'jv',          'nid';
  is $urn->nss,      'draft4-4242', 'nss';
  is $urn->fragment, 'foo',         'fragment';

  my $clone = $urn->clone;
  is $clone->host,      undef,                    'clone host';
  is $clone->scheme,    'urn',                    'clone scheme';
  is $clone->nid,       'jv',                     'clone nid';
  is $clone->nss,       'draft4-4242',            'clone nss';
  is $clone->fragment,  'foo',                    'clone fragment';
  is $clone->to_string, 'urn:jv:draft4-4242#foo', 'clone to_string';
};

subtest 'urn to_abs' => sub {
  my $urn = JSON::Validator::URI->new('urn:jv:draft4-4242#foo');

  my $abs = $urn->to_abs(JSON::Validator::URI->new('urn:jv:draft4-4242#bar'));
  is $abs->to_string, $urn->to_string, 'is_abs';

  $urn = JSON::Validator::URI->new('#foo');
  $abs = $urn->to_abs(JSON::Validator::URI->new('urn:jv:draft4-4242#bar'));
  is $abs->to_string, 'urn:jv:draft4-4242#foo', 'to_abs';
};

done_testing;
