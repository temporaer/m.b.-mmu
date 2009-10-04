# vim:tw=0:cindent
package MMU;
use Moose;
use Moose::Util::TypeConstraints;
use Carp qw/croak/;

has 'pagesbase' => (is => 'rw', isa => 'Str');
has 'memsize'   => (is => 'rw', isa => 'Str');
has 'activetask' => (is => 'rw', isa => 'Str', default => "none");
has 'maxalloc'  => (is => 'rw', isa => 'Int', required => 1);
has 'used_tasksets'  => (is => 'rw', isa => 'ArrayRef[Str]', default => sub{[]});
has 'avail_tasksets' => (is => 'rw', isa => 'ArrayRef[Str]');

sub init{
	my $self = shift;
	my $text =<<"	EOT";
	#include "system.h"
	#include "rt_mmu_regs.h"
	#include "rt_mem/rt_mem.h"
	#include "rt_mem/task.h"
	 
	 int main(void) {
	     task_t
	EOT
	$text .= join(' ', @{$self->avail_tasksets}) . ";\n";
	$text .= "initRTMem((void *) " . $self->pagesbase . ", " .  $self->memsize . ");";
	print "$text\n"
}

sub finish{
	my $self = shift;
	print "destroyRTMem();
// TODO: printf(...); // statistics
}\n";
}

sub free_task{
	my $self = shift;
	my $t    = shift;
	$self->used_tasksets( [ grep {$_ ne $t} @{$self->used_tasksets} ] );
	push @{ $self->avail_tasksets }, $t;
}
sub use_task{
	my $self = shift;
	my $t = shift(@{$self->avail_tasksets()});
	croak "No tasks left!" unless $t;
	push @{$self->used_tasksets()}, $t;
	return $t;
}

package Var;
use Moose;
use Moose::Util::TypeConstraints;
use Carp qw/croak/;

has 'name' => (is => 'ro', isa => 'Str', required => 1);
has 'size' => (is => 'ro', isa => 'Int', required => 1);
has 'task' => (is => 'ro', isa => 'Task', required => 1);
has 'isalloc' => (is => 'rw', isa => 'Bool', default => 0);

sub alloc{
	my $self = shift;
	croak "Var is already allocated!" if $self->isalloc;
	$self->isalloc(1);
	print "// begin_measure_time()\n";
	print "unsigned int * " . $self->name . " = (unsigned int*) malloc(" .  $self->size . ");\n" ;
	print "// end_measure_time()\n";
	print "// statistics: malloc " . $self->task->modus . "\n";
}

sub assign{
	my ($self,$idx,$val)  = @_;
	croak "Var is not yet allocated!"   unless $self->isalloc;
	croak "Index must be >0"            unless $idx>0;
	croak "Index must be <".$self->size unless $idx<$self->size;
	print "// begin_measure_time()\n";
	print $self->name . "[" . $val . "] = $val;\n";
	print "// end_measure_time()\n";
	print "// statistics: access-write " . $self->task->modus . "\n";
}

sub read{
	my ($self,$idx)  = @_;
	croak "Var is not yet allocated!"   unless $self->isalloc;
	croak "Index must be >=0"           unless $idx>=0;
	croak "Index must be <".$self->size unless $idx<$self->size;
	print "// begin_measure_time()\n";
	print "unsigned int _i" . int(rand(1E10)) . " = " .  $self->name . "[" .  $idx . "];\n";
	print "// end_measure_time()\n";
	print "// statistics: access-read ". $self->task->modus . "\n";
}
sub free{
	my ($self,$idx)  = @_;
	croak "Var is not yet allocated!"   unless $self->isalloc;
	$self->isalloc(0);
	print "// begin_measure_time()\n";
	print "free(". $self->name . ");\n";
	print "// end_measure_time()\n";
	print "// statistics: free\n";
}

package Task;
use Moose;
use Moose::Util::TypeConstraints;
use Carp qw/croak/;

enum 'Task::Mode' => qw( 
	RT_MMU_CONTROL_LINEAR 
	RT_MMU_CONTROL_SIMPLE 
	RT_MMU_CONTROL_TREE );
has 'name'      => (is => 'rw', isa => 'Str', required => 1);
has 'taskid'    => (is => 'rw', isa => 'Str', default => "n/a");
has 'modi'      => (is => 'rw', isa => 'ArrayRef[Task::Mode]', required => 1);
has 'modus'     => (is => 'rw', isa => 'Task::Mode', required => 0);
has 'tablebase' => (is => 'rw', isa => 'Str', required => 1);
has 'markerbase'=> (is => 'rw', isa => 'Str', required => 1);
has 'treebase'  => (is => 'rw', isa => 'Str', required => 1);
has 'created'   => (is => 'rw', isa => 'Bool', default => 0);
has 'activated' => (is => 'rw', isa => 'Bool', default => 0);
has 'mmu'       => (is => 'rw', isa => 'MMU', required => 1);
#has 'memsize'   => (is => 'rw', isa => 'Int', default => sub{shift()->mmu->memsize});
has 'vars'      => ( traits  => ['Array'],
	is => 'rw', 
	isa => 'ArrayRef[Var]',
	default => sub{[]},
	handles => { _add_var => 'push', _next_var => 'shift', '_all_vars' => 'elements' }
);

sub create {
	my $self = shift;
	croak "Recreating ".$self->name if ($self->created);
	$self->created(1);
	$self->taskid($self->mmu->use_task());
	$self->modus($self->modi->[int(rand(scalar(@{$self->modi})))]);
	print "createTask( &" . $self->taskid . ", // " . $self->name . "\n"
		."	("  . $self->modus  . " | RT_MMU_CONTROL_IE_MSK ), \n"
		."	(void*) (" . $self->mmu->pagesbase . " + " . $self->tablebase . "),\n"
		."	(void*) (" . $self->mmu->pagesbase . " + " . $self->markerbase . "),\n"
		."	(void*) (" . $self->mmu->pagesbase . " + " . $self->treebase . "),\n"
		."	" .  $self->mmu->memsize . ");\n";
}

sub activate{
	my $self = shift;
	croak "Activating before creating ".$self->name unless ($self->created);
	return "" if $self->mmu->activetask eq $self->name;
	$self->mmu->activetask( $self->name );
	$self->activated(1);
	print "activateTask( &" . $self->taskid . ");\n"
}

sub destroy{
	my $self = shift;
	croak "destroying before creating ".$self->name unless ($self->created);
	$self->created(0);
	$self->activated(0);
	$self->mmu->free_task($self->taskid);
	$self->mmu->activetask("none") if $self->mmu->activetask eq $self->name;
	print "destroyTask( &" . $self->taskid . "); // destroying ".$self->name. "\n";
}

sub del_var{
	my $self = shift;
	my $var  = shift;
	croak "Deleting from non-activated task" unless ($self->mmu->activetask eq $self->name);
	$self->vars( [ grep{ $_ != $var } $self->_all_vars ]  );
	$self->mmu->memsize( $self->mmu->memsize + $var->size );
	croak "No more memory left!" unless $self->mmu->memsize > 0;
	$var->free();
}

sub add_var{
	my $self = shift;
	my $var  = shift;
	croak "Adding to non-activated task" unless ($self->mmu->activetask eq $self->name);
	$self->_add_var( $var );
	$self->mmu->memsize( $self->mmu->memsize - $var->size );
	croak "No more memory left!" unless $self->mmu->memsize > 0;
	$var->alloc();
}



package main;
use Data::Dumper;
use List::Util qw/sum max/;
use YAML::Tiny;
use Statistics::Descriptive;

sub task_factory{
	my $cfg = shift;
	my $mmu = shift;
	my $x   = shift(@$cfg);
	push @$cfg, $x;
	new Task( mmu => $mmu, %$x); 
}

sub choose_weighted {
	my $weights  = shift;
	my $total    = 0;
	$total += $_ for @$weights;
	my $rand_val = $total * rand;
	my $i        = -1;
	$rand_val -= $weights->[++$i] while ($rand_val > 0);
	return $i;
}


my $yaml = YAML::Tiny->new;
my $cfg = $yaml->read('mmu.yml')->[0]; # 1st document in file

my $mmu = new MMU( memsize        => $cfg->{physical_size}, 
                   pagesbase      => $cfg->{physical_structures_base},
		   avail_tasksets => [map{"task$_"}(1..$cfg->{max_task_num})],
		   maxalloc       => $cfg->{physical_usage} * $cfg->{physical_size});
$mmu->init();

my (@tasks, @vars);   # create the max_task_num first tasks
push @tasks, map{ task_factory($cfg->{tasks}, $mmu) }(1..$cfg->{max_task_num});
$_->create() foreach(@tasks);

my $whole = $cfg->{lifetime_of_tasks} eq "whole"; # create set of possible actions
my @actions = qw/ malloc_var free_var assign_var read_var /;
push @actions, qw/ switch_task / unless $whole;

my $rnd_weights = [   # create probability table for actions (same order!)
  $cfg->{number_of_mallocs} ,    # malloc
  $cfg->{number_of_mallocs}    * $cfg->{free_prob} ,  # free
  (1-$cfg->{percent_of_reads}) * $cfg->{number_of_accesses},  # assign
     $cfg->{percent_of_reads}  * $cfg->{number_of_accesses},  # read
];
push @$rnd_weights, $cfg->{number_of_task_switches} unless $whole;  # switch_task 
my $s = sum @$rnd_weights;
@$rnd_weights = map{ $_/$s } @$rnd_weights;  # normalize probabilities

my $var_stats = Statistics::Descriptive::Full->new();
my $mem_stats = Statistics::Descriptive::Full->new();

my %actionstats = map{ $_ => 0 } (@actions, 'num_acc');
while(  $actionstats{malloc_var} < $cfg->{number_of_mallocs} or
	$actionstats{num_acc} < $cfg->{number_of_accesses}
){
   my $act = $actions[ choose_weighted( $rnd_weights ) ];
   next if($act eq "switch_task" and $actionstats{num_acc} < $actionstats{switch_task});
   if($act eq "malloc_var"){ # allocate a new variable
     next if $actionstats{$act} >= $cfg->{number_of_mallocs};
     my $size = int( $cfg->{malloc_size_min}+($cfg->{malloc_size_max}-$cfg->{malloc_size_min})*rand() );
     next if( (sum map{$_->size} @vars) + $size > $mmu->maxalloc );
     my $t    = $tasks[int(rand($#tasks+1))];
     my $v    = new Var(name=>"_var".int(rand(1E6)), size=>$size, task => $t);
     $t->activate();
     $t->add_var( $v );
     push @vars, $v;
   }
   if($act eq "free_var"){   # free a variable
     if($actionstats{malloc_var} >= $cfg->{number_of_mallocs} # cannot allocate new variable
       and scalar @vars == 1 ){                               # and only one variable left
       next;
     }
     next if scalar @vars == 0;
     my $v = shift @vars;
     $v->task->activate();
     $v->task->del_var( $v );
   }
   if($act eq "read_var"){   # read from some variable
     next unless $actionstats{read_var} < $cfg->{percent_of_reads} * $cfg->{number_of_accesses};
     next unless scalar @vars;
     my $v = $vars[int(rand($#vars+1))];
     $v->read( int(rand($v->size)) );
   }
   if($act eq "assign_var"){ # assign to a variable
     next unless $actionstats{assign_var} < (1-$cfg->{percent_of_reads}) * $cfg->{number_of_accesses};
     next unless scalar @vars;
     my $v = $vars[int(rand($#vars+1))];
     $v->assign( int(rand($v->size)), int(rand(10000)) );
   }
   if($act eq "switch_task"){  # remove a task and add another
     next if scalar @tasks <= 1;
     next if($actionstats{malloc_var}>=$cfg->{number_of_mallocs}  # all mallocs used up
          and $actionstats{num_acc}<$cfg->{number_of_accesses});  # still need to access variables -> dont del task!
     my $t = shift @tasks;
     @vars = grep{             # remove variables of this task
	if( $_->task == $t){ 
	$_->task->activate();
	$_->task->del_var($_); 0}
	else{ 1 }
     }@vars;
     $t->destroy();            # destroy task
     $t = task_factory($cfg->{tasks}, $mmu); # get new task
     $t->create();             
     unshift @tasks, $t;
   }
   $actionstats{$act}++;       # remember how often action was processed
   $actionstats{num_acc} = $actionstats{read_var} + $actionstats{assign_var};
   $var_stats->add_data(scalar @vars);  # statistics: number of variables
   $mem_stats->add_data($mmu->memsize); # statistics: memory size
}
# deallocate all remaining variables
map{ $_->task->activate(); $_->task->del_var($_); } @vars;
# deallocate all tasks
map{ $_->destroy(); } @tasks;
# deallocate MMU
$mmu->finish();

my $doc = YAML::Tiny::Dump(\%actionstats);
$doc =~ s|^---$||gm;
$doc =~ s|^|// |gm;
print  "// --------------- CALL STATISTICS ----------------- \\\\ \n";
print  $doc;
print  "// \n";
print  "// --------------- VARIABLE STATISTICS ------------- \\\\ \n";
print  "// Maximum number of allocated variables: " . $var_stats->max() . "\n";
printf "// Average number of allocated variables: %3.3f +/- %3.3f\n" , $var_stats->mean(), $var_stats->standard_deviation();
printf "//  \n";
print  "// --------------- MEMORY STATISTICS --------------- \\\\ \n";
printf "// Maximum number of available bytes:     %3.3f\n" , $mem_stats->max();
printf "// Minimum number of available bytes:     %3.3f\n" , $mem_stats->min();
printf "// Average number of available bytes:     %3.3f +/- %3.3f\n" , $mem_stats->mean(), $mem_stats->standard_deviation();
printf "// Average number of used bytes:          %3.3f\n" , $mmu->memsize - $mem_stats->mean();
