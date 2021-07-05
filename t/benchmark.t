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

  my $resolve_before = delete $attrs->{resolve_before};
  my $resolved_schema
    = $resolve_before && JSON::Validator::Schema::Draft7->new('http://json-schema.org/draft-07/schema#', %$attrs);

  $bm{$desc} = timeit 1 => sub {
    for (1 ... $n) {
      my $schema = $resolved_schema || JSON::Validator::Schema::Draft7->new(%$attrs);

      my $t0 = time;
      delete $schema->{errors};
      $schema->data('http://json-schema.org/draft-07/schema#')->resolve unless $resolve_before;
      push @resolve_t, (my $t1 = time) - $t0;

      push @errors, @{$schema->errors};
      push @validate_t, (my $t2 = time) - $t1;

      push @total_t, $t2 - $t0;
    }
  };

  ok !@errors, 'valid schema' or diag "@errors";

  my $rt = sprintf '%.3f', sum @resolve_t;
  ok $rt < 2, "$desc - resolve ${rt}s" unless $resolve_before;

  my $vt = sprintf '%.3f', sum @validate_t;
  ok $vt < 2, "$desc - validate ${vt}s";

  my $tt = sprintf '%.3f', sum @total_t;
  ok $tt < 2, "$desc - total ${tt}s";
}

__DATA__
# Sun Jul  4 11:38:21 2021
# n_times=200

ok 1 - valid schema
ok 2 - defaults - resolve 0.581s
not ok 3 - defaults - validate 3.126s
not ok 4 - defaults - total 3.707s

#   Failed test 'defaults - validate 3.126s'
#   at t/benchmark.t line 50.

#   Failed test 'defaults - total 3.707s'
#   at t/benchmark.t line 53.
ok 5 - valid schema
not ok 6 - resolve_before - validate 3.148s

#   Failed test 'resolve_before - validate 3.148s'
#   at t/benchmark.t line 50.
not ok 7 - resolve_before - total 3.148s

#   Failed test 'resolve_before - total 3.148s'
#   at t/benchmark.t line 53.
               s/iter       defaults resolve_before
defaults         3.71             --           -15%
resolve_before   3.14            18%             --
