# vim:tw=0:cindent
package MMU;
use Moose;
use Moose::Util::TypeConstraints;

enum 'MMU::PageBase' => qw( ALTMEMDDR_0_BASE ALTMEMDDR_1_BASE );
enum 'MMU::MemSize'  => qw( RT_MMU_0_DATA_SLAVE_SPAN RT_MMU_1_DATA_SLAVE_SPAN );
has 'pagesbase' => (is => 'rw', isa => 'MMU::PageBase');
has 'memsize'   => (is => 'rw', isa => 'MMU::MemSize');
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

	$text . join(' ', $self->avail_tasksets);
}

sub finish{
	my $self = shift;
	"destroyRTMem();\n}";
}

sub use_task{
	my $self = shift;
	my $t = shift(@{$self->avail_tasksets()});
	push @{$self->used_tasksets()}, $t;
	return $t;
}

package Var;
use Moose;
use Moose::Util::TypeConstraints;

has 'name' => (is => 'ro', isa => 'Str', required => 1);
has 'size' => (is => 'ro', isa => 'Int', required => 1);
has 'isalloc' => (is => 'rw', isa => 'Bool', default => 0);
has 'isfreed' => (is => 'rw', isa => 'Bool', default => 0);

sub alloc{
	my $self = shift;
	"unsigned int * " . $self->name . " = (unsigned int*) malloc(" .  $self->size . ");" 
}

sub assign{
	my ($self,$idx,$val)  = @_;
	die "Index must be >0"            unless $idx>0;
	die "Index must be <".$self->size unless $idx<$self->size;
	$self->name . "[" . $val . "] = $val;";
}

sub read{
	my ($self,$idx)  = @_;
	die "Index must be >0"            unless $idx>0;
	die "Index must be <".$self->size unless $idx<$self->size;
	"unsigned int _i" . int(rand(1E10)) . " = " .  $self->name . "[" .  $idx . "];";
}

package Task;
use Moose;
use Moose::Util::TypeConstraints;

enum 'Task::Mode' => qw( RT_MMU_CONTROL_LINEAR  RT_MMU_CONTROL_IE_MSK );
has 'name'      => (is => 'rw', isa => 'Str', required => 1);
has 'taskid'    => (is => 'rw', isa => 'Str', default => "n/a");
has 'modi'      => (is => 'rw', isa => 'ArrayRef[Task::Mode]', required => 1);
has 'tablebase' => (is => 'rw', isa => 'Int', required => 1);
has 'markerbase'=> (is => 'rw', isa => 'Int', required => 1);
has 'treebase'  => (is => 'rw', isa => 'Int', required => 1);
has 'memsize'   => (is => 'rw', isa => 'MMU::MemSize', required => 1);
has 'created'   => (is => 'rw', isa => 'Bool', default => 0);
has 'activated' => (is => 'rw', isa => 'Bool', default => 0);
has 'mmu'       => (is => 'rw', isa => 'MMU', required => 1);
has 'vars'      => ( traits  => ['Array'],
	is => 'rw', 
	isa => 'ArrayRef[Var]',
	default => sub{[]},
	handles => { add_var => 'push', next_var => 'shift' }
);

sub create {
	my $self = shift;
	die "Recreating ".$self->name if ($self->created);
	$self->created(1);
	$self->taskid($self->mmu->use_task());
	"createTask( &" . $self->taskid . ", "
		."("  . join(' | ', @{$self->modi}) . "), "
		."(void*) (" . $self->mmu->pagesbase . " + " . $self->tablebase . "),"
		."(void*) (" . $self->mmu->pagesbase . " + " . $self->markerbase . "),"
		."(void*) (" . $self->mmu->pagesbase . " + " . $self->treebase . "),"
		. $self->memsize . ");";
}

sub activate{
	my $self = shift;
	die "Activating before creating ".$self->name unless ($self->created);
	die "Reactivating ".$self->name if ($self->activated);
	$self->activated(1);
	"activateTask( &" . $self->taskid . ");"
}

sub alloc{
	my $self = shift;
	die "Freeing non-activated task" unless ($self->activated);
	$self->add_var( new Var(name => int(rand(1E10)), size => 80));
}

sub free{
	my $self = shift;
	die "Freeing non-created task" unless ($self->created);
	"free(" . $self->taskid . ");"
}


package main;
use Data::Dumper;

my $mmu = new MMU( memsize        => "RT_MMU_0_DATA_SLAVE_SPAN", 
                   pagesbase      => "ALTMEMDDR_0_BASE",  
		   avail_tasksets => [qw(task1 task2 task3)],
		   maxalloc       => 1E6);
print $mmu->init();

my $t1 = new Task( name    => "blubber", 
		mmu        => $mmu, 
		modi       => ['RT_MMU_CONTROL_IE_MSK', 'RT_MMU_CONTROL_LINEAR'],
		tablebase  => 0x01800000, 
		markerbase => 0x01400000,
		treebase   => 0x01420000,
		memsize    => "RT_MMU_0_DATA_SLAVE_SPAN");

print $t1->create(), "\n";
print $t1->activate(), "\n";
print $t1->alloc(), "\n";
print $t1->free(), "\n";
print $mmu->finish();
print "Used: ", Dumper($mmu->used_tasksets());
print "Avail: ", Dumper($mmu->avail_tasksets());
