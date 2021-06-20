BEGIN { $ENV{JSON_VALIDATOR_WARN_MISSING_FORMAT} = 0 }
use Mojo::Base -strict;
use Benchmark qw(cmpthese timeit :hireswallclock);
use JSON::Validator::Schema::Draft7;
use List::Util qw(sum);
use Test::More;
use Time::HiRes qw(time);

plan skip_all => 'TEST_BENCHMARK=500' unless my $n = $ENV{TEST_BENCHMARK};
diag sprintf "\n%s", scalar localtime;
diag "n_times=$n";

my %bm;
time_schema('defaults'       => {});
time_schema('resolve_before' => {resolve_before => 1});
cmpthese \%bm if $ENV{HARNESS_IS_VERBOSE};

done_testing;

sub time_schema {
  my ($desc, $attrs) = @_;
  my (@errors, @resolve_t, @validate_t, @total_t);

  my $resolve_before  = delete $attrs->{resolve_before};
  my $resolved_schema = $resolve_before
    && JSON::Validator::Schema::Draft7->new(%$attrs)->resolve('http://json-schema.org/draft-07/schema#');

  $bm{$desc} = timeit 1 => sub {
    for (1 ... $n) {
      my $schema = $resolved_schema || JSON::Validator::Schema::Draft7->new(%$attrs);

      my $t0 = time;
      delete $schema->{errors};
      $schema->resolve('http://json-schema.org/draft-07/schema#') unless $resolve_before;
      push @resolve_t, (my $t1 = time) - $t0;

      push @errors, @{$schema->errors};
      push @validate_t, (my $t2 = time) - $t1;

      push @total_t, $t2 - $t0;
    }
  };

  ok !@errors, 'valid schema' or diag "@errors";

  my $rt = sum @resolve_t;
  ok $rt < 2, "$desc - resolve ${rt}s" unless $resolve_before;

  my $vt = sum @validate_t;
  ok $vt < 2, "$desc - validate ${vt}s";

  my $tt = sum @total_t;
  ok $tt < 2, "$desc - total ${tt}s";
}

__DATA__
# Mon Jun 21 14:28:40 2021
# n_times=200

ok 1 - valid schema
ok 2 - defaults - resolve 1.20338559150696s
ok 3 - defaults - validate 1.76539778709412s
not ok 4 - defaults - total 2.96878337860107s

#   Failed test 'defaults - total 2.96878337860107s'
#   at t/benchmark.t line 53.
ok 5 - valid schema
ok 6 - resolve_before - validate 1.6137535572052s
ok 7 - resolve_before - total 1.61384391784668s
               s/iter       defaults resolve_before
defaults         2.96             --           -46%
resolve_before   1.61            84%             --
