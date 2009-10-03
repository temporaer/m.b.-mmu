# vim:tw=0:cindent
package MMU;
use Moose;
use Moose::Util::TypeConstraints;
use Carp qw/croak/;

enum 'MMU::PageBase' => qw( ALTMEMDDR_0_BASE ALTMEMDDR_1_BASE );
has 'pagesbase' => (is => 'rw', isa => 'MMU::PageBase');
has 'memsize'   => (is => 'rw', isa => 'Int');
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
// TODO: printf(...);
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
	print "unsigned int * " . $self->name . " = (unsigned int*) malloc(" .  $self->size . ");\n" 
}

sub assign{
	my ($self,$idx,$val)  = @_;
	croak "Var is not yet allocated!"   unless $self->isalloc;
	croak "Index must be >0"            unless $idx>0;
	croak "Index must be <".$self->size unless $idx<$self->size;
	print $self->name . "[" . $val . "] = $val;\n";
}

sub read{
	my ($self,$idx)  = @_;
	croak "Var is not yet allocated!"   unless $self->isalloc;
	croak "Index must be >=0"           unless $idx>=0;
	croak "Index must be <".$self->size unless $idx<$self->size;
	print "unsigned int _i" . int(rand(1E10)) . " = " .  $self->name . "[" .  $idx . "];\n";
}
sub free{
	my ($self,$idx)  = @_;
	croak "Var is not yet allocated!"   unless $self->isalloc;
	$self->isalloc(0);
	print "free(". $self->name . ");\n"
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
	print "createTask( &" . $self->taskid . ", // " . $self->name . "\n"
		."	("  . $self->modi->[int(rand(scalar(@{$self->modi})))]  . " | RT_MMU_CONTROL_IE_MSK ), \n"
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
use List::Util qw/sum/;
use YAML::Tiny;

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

my (@tasks, @vars);
push @tasks, map{ task_factory($cfg->{tasks}, $mmu) }(1..$cfg->{max_task_num});
map{ $_->create(), "\n" } @tasks;

my $whole = $cfg->{lifetime_of_tasks} eq "whole";
my @actions = qw/ malloc_var free_var assign_var read_var /;
push @actions, qw/ del_task add_task / unless $whole;

my $rnd_weights = [
  $cfg->{number_of_mallocs} ,  # malloc
  $cfg->{number_of_mallocs} ,  # free
  (1-$cfg->{percent_of_reads}) * $cfg->{number_of_accesses},  # assign
     $cfg->{percent_of_reads}  * $cfg->{number_of_accesses},  # read
];
push @$rnd_weights, (10, 10)  unless $whole;  # del_task, add_task  (TODO: specify probs!)
my $s = sum @$rnd_weights;
@$rnd_weights = map{ $_/$s } @$rnd_weights;

my %actionstats = map{ $_ => 0 } (@actions, 'num_acc');
while(  $actionstats{malloc_var} < $cfg->{number_of_mallocs} or
	$actionstats{num_acc} < $cfg->{number_of_accesses}
){
   my $act = $actions[ choose_weighted( $rnd_weights ) ];
   if($act eq "malloc_var"){
     next if $actionstats{$act} >= $cfg->{number_of_mallocs};
     my $size = int( $cfg->{malloc_size_min}+($cfg->{malloc_size_max}-$cfg->{malloc_size_min})*rand() );
     my $t    = $tasks[int(rand($#tasks+1))];
     my $v    = new Var(name=>"_var".int(rand(1E6)), size=>$size, task => $t);
     $t->activate();
     $t->add_var( $v );
     push @vars, $v;
   }
   if($act eq "free_var"){
     if($actionstats{malloc_var} >= $cfg->{number_of_mallocs} # cannot allocate new variable
       and scalar @vars == 1 ){                               # and only one variable left
       next;
     }
     next if scalar @vars == 0;
     my $v = shift @vars;
     $v->task->activate();
     $v->task->del_var( $v );
   }
   if($act eq "read_var"){
     next unless $actionstats{read_var} < $cfg->{percent_of_reads} * $cfg->{number_of_accesses};
     next unless scalar @vars;
     my $v = $vars[int(rand($#vars+1))];
     $v->read( int(rand($v->size)) );
   }
   if($act eq "assign_var"){
     next unless $actionstats{assign_var} < (1-$cfg->{percent_of_reads}) * $cfg->{number_of_accesses};
     next unless scalar @vars;
     my $v = $vars[int(rand($#vars+1))];
     $v->assign( int(rand($v->size)), int(rand(10000)) );
   }
   if($act eq "add_task"){
     next if scalar @tasks >= $cfg->{max_task_num};
     print "-----> Adding Task: currently: ", scalar(@tasks), "\n";
     my $t = task_factory($cfg->{tasks}, $mmu);
     $t->create();
     unshift @tasks, $t;
   }
   if($act eq "del_task"){
     next if scalar @tasks <= 1;
     next if($actionstats{malloc_var}>=$cfg->{number_of_mallocs}  # all mallocs used up
          and $actionstats{num_acc}<$cfg->{number_of_accesses});  # still need to access variables -> dont del task!
     my $t = shift @tasks;
     @vars = grep{
	if( $_->task == $t){ 
	$_->task->activate();
	$_->task->del_var($_); 0}
	else{ 1 }
     }@vars;
     $t->destroy();
   }
   $actionstats{$act}++;
   $actionstats{num_acc} = $actionstats{read_var} + $actionstats{assign_var};
}
while(scalar @vars){
  my $v = shift @vars;
  $v->task->activate();
  $v->task->del_var($v);
}
while(scalar @tasks){
  my $t = pop @tasks;
  $t->destroy();
}
$mmu->finish();

print Dumper(\%actionstats);
