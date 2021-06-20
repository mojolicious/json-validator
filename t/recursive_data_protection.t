use Mojo::Base -strict;
use JSON::Validator;
use JSON::Validator::Schema;
use Mojo::Util 'monkey_patch';
use Scalar::Util qw(refaddr);
use Test::More;

my ($original_validate, %ref_counts) = (\&JSON::Validator::Schema::_validate);
monkey_patch 'JSON::Validator::Schema', _validate => sub {
  my ($self, $data, $path, $schema) = @_;
  $ref_counts{refaddr($data)}++ if ref $data;
  goto &$original_validate;
};

for ([1, 1], [0, 3]) {
  my ($enabled, $exp_ref_counts) = @$_;
  my $object = {level1 => {level2 => {level3 => 'Test'}}};
  my $data   = [$object, $object, $object];

  %ref_counts = ();

  JSON::Validator->new->recursive_data_protection($enabled)->schema(schema())->validate($data);

  is $ref_counts{refaddr($object->{level1}{level2})}, $exp_ref_counts, "recursive_data_protection($enabled)";
}

done_testing;

sub schema {
  return {
    type  => 'array',
    items => {
      type       => 'object',
      properties => {
        level1 => {
          type       => 'object',
          properties => {level2 => {type => 'object', properties => {level3 => {type => 'string'}}}}
        }
      }
    }
  };
}
