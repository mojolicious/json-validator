use Mojo::Base -strict;
use JSON::Validator;
use Test::More;

my $jv = JSON::Validator->new->schema({foo => [{y => 'foo'}], bar => [{y => 'first'}, {y => 'second'}, {z => 'zzz'}]});

is $jv->get('/bar/2/z'), 'zzz', 'get /bar/2/z';
is $jv->get([qw(nope 404)]), undef, 'get /nope/404';
is_deeply $jv->get([qw(bar 0)]),                {y => 'first'}, 'get /bar/0';
is_deeply $jv->schema->get([qw(bar 0)], undef), {y => 'first'}, 'schema->get /bar/0';
is_deeply $jv->schema->get([qw(bar 0)]),        {y => 'first'}, 'schema->get $ARRAY';
ok $jv->schema->contains('/bar/0'), 'contains';

# This is not officially supported. I think maybe the callback version is the way to go,
# since it allows the JSON pointer to be passed on as well.
is_deeply $jv->get(['bar', undef, 'y']), ['first', 'second', undef], 'get /bar/undef/y';
is_deeply $jv->get([undef, undef, 'y']), [['first', 'second', undef], ['foo']], 'get /undef/undef/y';
is_deeply $jv->get([undef, undef, 'y'])->flatten, ['first', 'second', undef, 'foo'], 'get /undef/undef/y flatten';

my @res;
$jv->schema->get(['bar', undef, 'y'], sub { push @res, [@_] });
is_deeply \@res, [['first', '/bar/0/y'], ['second', '/bar/1/y']], 'schema->get /bar/undef/y, $cb';

@res = ();
$jv  = $jv->schema->get(['bar', undef, 'y'], sub { push @res, [@_] });
is_deeply \@res, [['first', '/bar/0/y'], ['second', '/bar/1/y']], 'schema->get /bar/undef/y, $cb';

done_testing;
