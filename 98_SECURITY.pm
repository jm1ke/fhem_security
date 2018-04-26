#########################################################################
# $Id$
# fhem Modul to create and maintain notifies and at devices to build an alarm system
#   
#     This file is part of fhem.
# 
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
# 
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
# 
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
#     versioning: MAJOR.MINOR.PATCH, increment the:
#     MAJOR version when you make incompatible API changes
#      - includes changing CLI options, changing log-messages
#     MINOR version when you add functionality in a backwards-compatible manner
#      - includes adding new features and log-messages (as long as they don't break anything existing)
#     PATCH version when you make backwards-compatible bug fixes.
#
##############################################################################
#   Changelog:
#
#   2018-02-02  initial release
#   0.9.2       aggregated at and notifies for arm/disarm actions
#   0.9.3       get device validate to read json new in and validate, need to run reload after that!
#               attr secRoom in which, if set, the actors and sensors will be gathered
#               grouping is on by default atm
#   0.9.4       improved handling of levels with ignore-state 1
#   0.9.5       removed reload from define to avoid configfile: sec0sensorNTFY already defined, delete it first 
#
##############################################################################

package main;

use strict;                          
use warnings;                        
use Data::Dumper;
use Time::HiRes qw(gettimeofday);    
use LWP::Simple qw($ua get);
use POSIX;
use JSON; #fixme,...
die "JSON missing!" unless(eval{require JSON});

sub SECURITY_Initialize($);
sub SECURITY_Define($$);
sub SECURITY_Undef($$);
sub SECURITY_Set($@);
sub SECURITY_Get($@);
sub SECURITY_Attr(@);
sub SECURITY_GetUpdate($);

my %secCmds = (
    'reload'   => 'noArg',
    'arm'      => 'noArg',        #no arg? needs a level, could i read in json here?
    'disarm'   => 'noArg',        #no arg?
    'remove'   => 'noArg',        #no arg?
);
my $secVersion = '0.9.5';

sub SECURITY_Initialize($){

    my ($hash) = @_;

    $hash->{DefFn}      = "SECURITY_Define";
    $hash->{UndefFn}    = "SECURITY_Undef";
    $hash->{SetFn}      = "SECURITY_Set";
    $hash->{GetFn}      = "SECURITY_Get";

    $hash->{AttrFn}     = "SECURITY_Attr";
    $hash->{AttrList}   = 
      "disable:0,1 verbose secRoom secNoFile:0,1 " .
      $readingFnAttributes;  

}

sub SECURITY_Define($$){

    my ($hash, $allDefs) = @_;
    
    my @deflines = split('\n',$allDefs);
    my @apiDefs  = split('[ \t]+', shift @deflines);
    
    $hash->{NAME}    = $apiDefs[0];
    $hash->{VERSION} = $secVersion;
    my $name = $hash->{NAME};

    #clear all readings
    foreach my $clearReading ( keys %{$hash->{READINGS}}){
        Log3 $hash, 5, "SECURITY Define ($name) READING: $clearReading deleted";
        delete($hash->{READINGS}{$clearReading}); 
    }
    
    # put in default verbose level
    $attr{$name}{"verbose"} = 1 if !$attr{$name}{"verbose"};
    
    readingsSingleUpdate( $hash, "state", "Initialized", 1 );
    
    # SECURITY_reload($hash); #this will lead to defmod notifies/ats on startup before config is loaded which will lead to configfile: sec0sensorNTFY already defined, delete it first  

    Log3 $hash, 1, "SECURITY Define ($name) defined ".$hash->{NAME};
    return undef;
}


sub SECURITY_Undef($$){      
    my ( $hash, $arg ) = @_;
    #fixme, clear all sensor notifies, ats, action notifies etc.
    SECURITY_remove($hash);
    return undef;                  
}    

  
#
# Attr command 
#########################################################################
sub SECURITY_Attr(@){

	my ($cmd,$name,$attrName,$attrValue) = @_;
    # $cmd can be "del" or "set" 
    # $name is device name
    my $hash = $defs{$name};

    if ($cmd eq "set") {        
        addToDevAttrList($name, $attrName);
        Log3 $hash, 4, "SECURITY Attr ($name)  attrName $attrName set to attrValue $attrValue";
    }
    if($attrName eq "disable" && $attrValue eq "1"){
        readingsSingleUpdate( $hash, "state", "disabled", 1 );
    }
    return undef;
}

sub SECURITY_remove{
    my $hash = shift();
    my $name = $hash->{NAME};

    undef $hash->{helper}->{'armed'};       #this will hold all names of armed levels
    undef $hash->{helper}->{'disarmed'};    # -"-
    undef $hash->{helper}->{'armwait'};     # -"-
    undef $hash->{helper}->{'alarmed'};     # -"-
    undef $hash->{helper}->{'trigger'};     # this will hold the comindes notifies by time/regex etc prior creation
    undef $hash->{helper}->{'state-level'}; #this does hold the names of levels which will be represented on device state
    
    foreach my $level (0..$#{$hash->{JSON}}){
        Log3 $hash, 2, "SECURITY_remove ($name > ".$hash->{JSON}->[$level]->{name}.") cleaning up...";
        fhem("delete sec".$level."sensorNTFY")      if $defs{"sec".$level."sensorNTFY"};
        fhem("delete sec".$level."autoarmAT")       if $defs{"sec".$level."autoarmAT"};
        fhem("delete sec".$level."autoarmNTFY")     if $defs{"sec".$level."autoarmNTFY"};
        fhem("delete sec".$level."autodisarmAT")    if $defs{"sec".$level."autodisarmAT"};
        fhem("delete sec".$level."autodisarmNTFY")  if $defs{"sec".$level."autodisarmNTFY"};
    }
    
    foreach my $defName (keys %defs){
        next if $defName !~ m/sec.*(AT|NTFY)$/;
        Log3 $hash, 2, "SECURITY_remove ($name) device $defName probably from us";
        if($defs{$defName}->{DEF} =~m/$name/){
            Log3 $hash, 1, "SECURITY_remove ($name) device is bound to our SECURITY device ($name), deleting it"; 
            fhem("delete $defName");
        }
    }
    
    # fixme: remove all secSensor and secActor from devices
    # fixme: remove the secRoom from all devices if set
    
}
    
sub SECURITY_reload{
    my $hash = shift();

    my $name = $hash->{NAME};
    if(AttrVal($name,"secNoFile",0)){
        eval {
            my $testJson = decode_json($hash->{DEF}); 
            1;
        };
        if($@){
            Log3 $hash, 1, "SECURITY reload ($name) no valid JSON provided in DEF...";
            return;
        }else{
            $hash->{JSON} = JSON->new->utf8(0)->decode($hash->{DEF});
        }
        
    }else{
        $hash->{JSON} = SECURITY_jsonFromFile($hash);    
    }
    
    SECURITY_validateJSON($hash, $hash->{JSON});
    SECURITY_remove($hash);
    
    foreach my $level (0..$#{$hash->{JSON}}){
        Log3 $hash, 2, "SECURITY reload ($name > ".$hash->{JSON}->[$level]->{name}.") creating...";
        
        push @{$hash->{helper}->{'state-level'}}, $hash->{JSON}->[$level]->{name} if $hash->{JSON}->[$level]->{configuration}->{'ignore-state'} ne 1;
        
        SECURITY_createLevelSensors($hash,$level);
    }
    
    SECURITY_createTrigger($hash);
    
    return undef;

}


sub SECURITY_collectTrigger($@){
    # SECURITY_collectTrigger($hash,$level,'at',$at,$action);
    my $hash    = shift();  
    my $level   = shift();  #0 or 1
    my $type    = shift();  # at|arm|disarm
    my $spec    = shift();  #22:00|notify match
    my $action  = shift();  # set light on
    my $name  = $hash->{NAME};

    if($type eq 'at'){
        Log3 $hash, 1, "SECURITY ($name > $level) collecting AT $spec $action "; 
        push @{$hash->{'helper'}->{'trigger'}->{at}->{$spec}}, $action;
    }elsif($type =~ m/^arm$|^disarm$/){
        Log3 $hash, 1, "SECURITY ($name > $level) collecting notify  $action "; 
        push @{$hash->{'helper'}->{'trigger'}->{$type}->{$spec}}, $action;
    }
    
}


sub SECURITY_createTrigger($@){
    my $hash    = shift();
    my $name  = $hash->{NAME};
    
    
    foreach my $timeSpec (keys %{$hash->{'helper'}->{'trigger'}->{at}}){
        Log3 $hash, 1, "SECURITY_createTrigger ($name) creating trigger at $timeSpec"; 
        my $str = $timeSpec;
        $str =~ s/://g;
        #fixme test me ;; is right here? 
        my $cmd =  "defmod secauto_".$str."AT at *$timeSpec ".join(';;', @{$hash->{'helper'}->{'trigger'}->{at}->{$timeSpec}});
        
        Log3 $hash, 3, "SECURITY_createTrigger ($name) cmd $cmd"; 
        fhem($cmd);

    }  
    
    my @autoActions =('arm','disarm');
    foreach my $autoAction (@autoActions){
        my $notifySpecCount=0;
        foreach my $notifySpec (keys %{$hash->{'helper'}->{'trigger'}->{$autoAction}}){
            Log3 $hash, 1, "SECURITY_createTrigger ($name) creating trigger notify $autoAction $notifySpec"; 
            my $cmd =  "defmod secauto_".$autoAction."_".$notifySpecCount."NTFY notify $notifySpec ".join(';;', @{$hash->{'helper'}->{'trigger'}->{$autoAction}->{$notifySpec}});
            Log3 $hash, 3, "SECURITY_createTrigger ($name) cmd $cmd"; 
            fhem($cmd);
            $notifySpecCount++;
        }
    }
    


}

sub SECURITY_createLevelSensors($@){
    # this creates the sensor notifies 
    # will be called on DEF / reload
    my $hash = shift;
    my $level = shift;
    my $name  = $hash->{NAME};
    
    if(!defined($hash->{JSON}->[$level])){
        Log3 $hash, 1, "SECURITY createLevelSensors ($name) level $level not defined";
        return "SECURITY createLevelSensors  ($name) level $level not defined";
    }
    my $levelName = $hash->{JSON}->[$level]->{name};
    
    Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) setting up sensor notifies";
    readingsSingleUpdate( $hash, $levelName, 'disarmed', 1 );
    SECURITY_updateState($hash,'disarmed',$level);
    
    my @sensorRegexs;
    foreach my $sensor (@{$hash->{JSON}->[$level]->{sensors}}){
        my @existingGroups = split(',', AttrVal($sensor->{name},"group","") );
        push @existingGroups, 'secSensors' if !SECURITY_arrayGrep(\@existingGroups, 'secSensors');
        fhem("attr $sensor->{name} group ".join(',', @existingGroups)); 
        push @sensorRegexs, $sensor->{regex};
        
        if(AttrVal($name,"secRoom",undef)){
            Log3 $hash, 1, "SECURITY_createLevelSensors ($name) assigning ".$sensor->{name}." to room ".AttrVal($name,"secRoom",undef); 
            my @existingRooms = split(',', AttrVal($sensor->{name},"room","") );
            push @existingRooms, AttrVal($name,"secRoom",undef) if !SECURITY_arrayGrep(\@existingRooms, AttrVal($name,"secRoom",undef));
            fhem("attr $sensor->{name} room ".join(',', @existingRooms)); 
        }
    }

    foreach my $actor (@{$hash->{JSON}->[$level]->{actions}}){
        my @existingGroups = split(',', AttrVal($actor->{name},"group","") );
        push @existingGroups, 'secActors' if !SECURITY_arrayGrep(\@existingGroups, 'secActors');
        fhem("attr $actor->{name} group ".join(',', @existingGroups)); 
        
        if(AttrVal($name,"secRoom",undef)){
            Log3 $hash, 1, "SECURITY_createLevelSensors ($name) assigning ".$actor->{name}." to room ".AttrVal($name,"secRoom",undef); 
            my @existingRooms = split(',', AttrVal($actor->{name},"room","") );
            push @existingRooms, AttrVal($name,"secRoom",undef) if !SECURITY_arrayGrep(\@existingRooms, AttrVal($name,"secRoom",undef));
            fhem("attr $actor->{name} room ".join(',', @existingRooms)); 
        }
    }

    #fixme, only if @sensorRegexs
    if(@sensorRegexs){
        my $cmd = "defmod sec".$level."sensorNTFY notify (".join('|',@sensorRegexs).') {SECURITY_triggerLevel("'.$name.'",'.$level.',"$NAME","$EVENT")}';
        Log3 $hash, 3, "SECURITY createLevelSensors ($name > $levelName) cmd $cmd"; 
        fhem($cmd);
    }else{
        Log3 $hash, 3, "SECURITY createLevelSensors ($name > $levelName) no sensors defined"; 
    }
    
    
    my @autoActions = ('arm','disarm'); # will use auto-* below
    AUTOACTION: foreach my $autoAction (@autoActions){
    
        if( defined($hash->{JSON}->[$level]->{$autoAction}->{'at'}) && ref $hash->{JSON}->[$level]->{$autoAction}->{'at'} eq 'ARRAY' ){ #match against hash or string here
            # expects a at and event here, to match BOTH
            my $complexAutoAction;
            foreach my $autoAtAction (@{$hash->{JSON}->[$level]->{$autoAction}->{'at'}}){
                if (ref $autoAtAction ne 'HASH' ){
                    # assume this is a time
                    Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) complex $autoAction rule, AT $autoAtAction"; 
                    $complexAutoAction->{at} = $autoAtAction; #this just contains the 08:00 string
                }else{
                    # assume this is an event spec
                    my @reqElems = ('name','reading','op','value');
                    foreach my $reqElem (@reqElems){
                        next if defined($autoAtAction->{$reqElem}); #thats what we want
                        Log3 $hash, 1, "SECURITY createLevelSensors ($name > $levelName) ERROR: cannot setup complex $autoAction rule, $reqElem not defined on event spec"; 
                        next AUTOACTION;
                    }
                    
                    Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) complex $autoAction rule, event $autoAtAction->{name}: $autoAtAction->{reading} must be $autoAtAction->{value}"; 
                    push @{$complexAutoAction->{events}}, 'ReadingsVal("'.$autoAtAction->{name}.'","'.$autoAtAction->{reading}.'",undef) '.$autoAtAction->{op}.' "'.$autoAtAction->{value}.'"';
                }
            }
            
            if($complexAutoAction->{at}){
                SECURITY_collectTrigger($hash,$level,'at',$complexAutoAction->{at},"{if(".join(' && ', @{$complexAutoAction->{events}})."){fhem('set $name $autoAction $levelName')}}"); #testme uses name
            }else{
                Log3 $hash, 1, "SECURITY ($name) wrong spec for $levelName $autoAction AT";
            }
            
        
        }elsif( defined($hash->{JSON}->[$level]->{$autoAction}->{'at'}) && $hash->{JSON}->[$level]->{$autoAction}->{'at'}){ #match against hash or string here
            Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) setting up auto- $autoAction at";
            SECURITY_collectTrigger($hash,$level,'at',$hash->{JSON}->[$level]->{$autoAction}->{at},"set $name $autoAction $levelName"); #testme with levelName

        }else{
            Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) no auto-arm AT defined"; 
        }
    
        if(defined($hash->{JSON}->[$level]->{$autoAction}->{'event'}) && ref $hash->{JSON}->[$level]->{$autoAction}->{'event'} eq 'ARRAY'){
            Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) setting up auto- $autoAction event";

            my @autoArmEvents;
            foreach my $autoEvent (@{$hash->{JSON}->[$level]->{$autoAction}->{'event'}}){
                my @fields;
                push @fields, $autoEvent->{name} if $autoEvent->{name};
                push @fields, $autoEvent->{reading} if $autoEvent->{reading};
                # push @fields, $autoEvent->{op} if $autoEvent->{op};
                push @fields, $autoEvent->{value} if defined($autoEvent->{value});
                push @fields, $autoEvent->{regex} if defined($autoEvent->{regex});
                push @autoArmEvents, join(':',@fields);
            }
            
            if(@autoArmEvents){
                SECURITY_collectTrigger($hash,$level,$autoAction,join('|',@autoArmEvents), "set $name $autoAction $levelName");
            }else{
                Log3 $hash, 3, "SECURITY createLevelSensors ($name > $levelName) no auto $autoAction events defined"; 
            }
            
            
        }else{
        Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) no auto- $autoAction defined"; 
        }
    }
    
    if(defined($hash->{JSON}->[$level]->{configuration}->{'on-load'}) && $hash->{JSON}->[$level]->{configuration}->{'on-load'} eq 'armed'){
        Log3 $hash, 2, "SECURITY createLevelSensors ($name > $levelName) auto-arming due to on-load setting";
        # SECURITY_ArmLevel($name,$level);
        fhem("set $name arm $level");
    }
    


}

sub SECURITY_ArmLevel($@){
    # this will execute the arm action
    # this will set the reading of the level
    my $name  = shift;
    my $level = shift;
    my $hash = $defs{$name};

    if(!defined($hash->{JSON}->[$level])){
        Log3 $hash, 1, "SECURITY ArmLevel ($name) level $level not defined";
        return "SECURITY ArmLevel ($name) level $level not defined";
    }
    
    Log3 $hash, 1, "SECURITY ArmLevel ($name) level ".$hash->{JSON}->[$level]->{name}." armed!";
    
    SECURITY_updateState($hash,'armed',$level);

    fhem("setreading $name ".$hash->{JSON}->[$level]->{name}.' armed');
    if($hash->{JSON}->[$level]->{arm}->{action}){
        my $cmd = $hash->{JSON}->[$level]->{arm}->{action};
        Log3 $hash, 2, "SECURITY ArmLevel ($name) cmd: $cmd"; 
        fhem($cmd);
    }
}


sub SECURITY_getLevelStatus{
    my $hash = shift();
    my $level = shift();
    
    my $name = $hash->{NAME};
    my $levelName = $hash->{JSON}->[$level]->{name};

    if(SECURITY_arrayGrep($hash->{helper}->{armwait}, $levelName)){
        return "armwait";
    }elsif(SECURITY_arrayGrep($hash->{helper}->{armed}, $levelName)){
        return "armed";
    }elsif(SECURITY_arrayGrep($hash->{helper}->{alarmed}, $levelName)){
        return "alarmed";
    }elsif(SECURITY_arrayGrep($hash->{helper}->{disarmed}, $levelName)){
        return "disarmed";
    }else{
        return $hash->{READINGS}->{$levelName}->{VAL};
    }
    
}

sub SECURITY_updateState{
    my $hash = shift();
    my $action = shift();
    my $level = shift();
    my $name = $hash->{NAME};
    my $levelName = $hash->{JSON}->[$level]->{name};

    my @actions = ('armed','disarmed','armwait','alarmed');
    foreach my $act (@actions){
        # remove current level from any helper status
        my ($index) = grep { $hash->{helper}->{$act}->[$_] eq $levelName } 0..$#{$hash->{helper}->{$act}}; 
        if (defined $index) {splice( @{$hash->{helper}->{$act}}, $index, 1); }
    }
    # insert current level
    if($hash->{JSON}->[$level]->{configuration}->{'ignore-state'}){
        Log3 $hash, 2, "SECURITY ($name) skipping to set $levelName in helper";  #this is bad :( because the device state will not be represented correctly
    }else{
        push @{$hash->{helper}->{$action}}, $levelName;
    }
    
    if(scalar @{$hash->{helper}->{'alarmed'}} ne 0){
        Log3 $hash, 5, "SECURITY updateState ($name > $levelName) count alarmed level ".scalar @{$hash->{helper}->{'alarmed'}};
        
        my $state='alarmed';
        $state = join(' ',map { ReadingsVal($name,$_,undef) } @{$hash->{helper}->{'alarmed'}});
        readingsSingleUpdate( $hash, "state", "$state", 1 );
        
    }elsif(scalar @{$hash->{helper}->{'armed'}} == scalar @{$hash->{helper}->{'state-level'}}){
        Log3 $hash, 5, "SECURITY updateState ($name > $levelName) count armed level ".scalar @{$hash->{helper}->{'armed'}}; 
        readingsSingleUpdate( $hash, "state", "armed", 1 );
    
    }elsif(scalar @{$hash->{helper}->{'disarmed'}} ==  scalar @{$hash->{helper}->{'state-level'}}){
        Log3 $hash, 5, "SECURITY updateState ($name > $levelName) count disarmed level ".scalar @{$hash->{helper}->{'disarmed'}}; 
        readingsSingleUpdate( $hash, "state", "disarmed", 1 );
    
    }elsif(scalar @{$hash->{helper}->{'armwait'}} ne 0){
        Log3 $hash, 5, "SECURITY updateState ($name > $levelName) count disarmed level ".scalar @{$hash->{helper}->{'armwait'}}; 
        readingsSingleUpdate( $hash, "state", "armwait", 1 );
    
    }else{
        Log3 $hash, 5, "SECURITY updateState ($name > $levelName) count armed level ".scalar @{$hash->{helper}->{'armed'}}; 
        Log3 $hash, 5, "SECURITY updateState ($name > $levelName) count disarmed level ".scalar @{$hash->{helper}->{'disarmed'}}; 
        readingsSingleUpdate( $hash, "state", "partially armed", 1 );
    }

    return;
}

sub SECURITY_triggerLevel($@){
    # this gets activated through the sensor notify
    # excute like this {SECURITY_triggerLevel($name,$level,$DEVICE,$EVENT)}
    my $name  = shift;
    my $level = shift;
    my $callingDevice = shift;
    my $callingEvent = shift;
    
    my $hash = $defs{$name};
    
    if(!defined($hash->{JSON}->[$level])){
        Log3 $hash, 1, "SECURITY triggerLevel ($name) level $level not defined";
        return "SECURITY triggerLevel ($name) level $level not defined";
    }
    
    my $levelName = $hash->{JSON}->[$level]->{name};

    Log3 $hash, 2, "SECURITY triggerLevel ($name > $levelName) got activated through $callingDevice and event $callingEvent";
    Log3 $hash, 3, "SECURITY triggerLevel ($name > $levelName) level = ".$hash->{READINGS}->{$hash->{JSON}->[$level]->{name}}->{VAL}; 
    
    # save the last action in a reading #fixme, maybe per attr
    # readingsSingleUpdate( $hash, 'lastTrigger', $callingDevice.' '.$callingEvent, 1 );

    
    if($hash->{READINGS}->{$hash->{JSON}->[$level]->{name}}->{VAL} !~ m/^armed$|alarm/i){ #fixme, via helper oder reading..!? #fixme to getlevelState
        Log3 $hash, 2, "SECURITY triggerLevel ($name > $levelName) $levelName is not armed, triggerLevel exit"; 
    }else{
        
        my @alarmMsg;
        foreach my $sensor (@{$hash->{JSON}->[$level]->{sensors}}){
            next if $sensor->{name} ne $callingDevice;
            push @alarmMsg, $sensor->{msg};
        }
        my $alarmMsg = join(" ",@alarmMsg);
        fhem("setreading $name $levelName alarm $alarmMsg");
        SECURITY_updateState($hash,'alarmed',$level);


        foreach my $action (@{$hash->{JSON}->[$level]->{actions}}){
            if(defined($action->{delay}) && $action->{delay} && $action->{activate}){
                my $alarmAction = $action->{activate};
                   $alarmAction =~ s/%alarmMsg/$alarmMsg/g;
                   
                if($alarmAction =~ m/(?<!;);(?!;)/){
                    # fixme testme a delayed action with two cmd and only 1 ;
                    Log3 $hash, 1, "SECURITY triggerLevel ($name > $levelName) replacing ; with ;; on action ".$action->{name}; 
                    $alarmAction =~ s/(?<!;);(?!;)/;;/g;
                }

                Log3 $hash, 2, "SECURITY triggerLevel ($name > $levelName) executing action $alarmAction in ".$action->{delay}; 
                my $cmd = "defmod sec".$level."action".$action->{name}."AT at +".$action->{delay}.' '.$alarmAction;
                Log3 $hash, 2, "SECURITY triggerLevel ($name > $levelName) cmd $cmd"; 
                fhem($cmd);
            }elsif($action->{activate}){
                my $alarmAction = $action->{activate};
                   $alarmAction =~ s/%alarmMsg/$alarmMsg/g;
                   
                Log3 $hash, 2, "SECURITY triggerLevel ($name > $levelName) executing action \"$alarmAction\" now"; 
                fhem($alarmAction);
            }else{
                Log3 $hash, 2, "SECURITY triggerLevel ($name > $levelName) action ".$action->{name}." has no activate defined"; 
            }
        }  
    }
    
    return undef;
   
}


sub SECURITY_disarmLevel($@){
    # executes the disarm action
    # executes the deactivate actions if the level was alarmed
    my $name  = shift;
    my $level = shift;
    my $hash = $defs{$name};
    my $levelName = $hash->{JSON}->[$level]->{name};

    if(!defined($hash->{JSON}->[$level])){
        Log3 $hash, 2, "SECURITY disarmLevel ($name) level $level not defined";
        return "SECURITY disarmLevel ($name) level $level not defined";
    }
    
    fhem($hash->{JSON}->[$level]->{disarm}->{action});

    fhem("delete sec".$level."armAT")     if $defs{"sec".$level."armAT"};       #this is the AT
    
    foreach my $action (@{$hash->{JSON}->[$level]->{actions}}){
    
    
        #execute unset if available
#does not disable if no deactivate is set but delayed action        if (defined($action->{deactivate}) && $action->{deactivate} && $hash->{READINGS}->{$hash->{JSON}->[$level]->{name}}->{VAL} =~ m/alarm/i ){ #fixme check this via the helper 
        if ($hash->{READINGS}->{$hash->{JSON}->[$level]->{name}}->{VAL} =~ m/alarm/i ){ #fixme check this via the helper
            # deactivate is set for this action
            # alarm is rised
            
            if(!$action->{delay} || !$defs{"sec".$level."action".$action->{name}."AT"}){
                # we had no delay, or it has already been called
                Log3 $hash, 2, "SECURITY disarmLevel ($name > $levelName) ".$action->{name}." has been called, executing action ".$action->{deactivate};
                fhem($action->{deactivate}) if $action->{deactivate};
                
            }elsif($defs{"sec".$level."action".$action->{name}."AT"}){
                # we have a delayed configured, but it has not been called yet
                Log3 $hash, 2, "SECURITY disarmLevel ($name > $levelName) ".$action->{name}." has not been called, NOT executing deactivate, but deleting AT";
                fhem("delete sec".$level."action".$action->{name}."AT"); #fixme if
            }else{
                Log3 $hash, 2, "SECURITY disarmLevel ($name > $levelName) unexpected condition occured, deactivating device and deleting AT?"; 
                fhem($action->{deactivate}) if $action->{deactivate};
                fhem("delete sec".$level."action".$action->{name}."AT"); #fixme if
            }
        }elsif($action->{deactivate}){
            # level has not been alarmed
            Log3 $hash, 5, "SECURITY disarmLevel ($name > $levelName) deactivate cmd ".$action->{deactivate}." will not be executed, no alarm rised"; 
        }else{
            Log3 $hash, 5, "SECURITY disarmLevel ($name > $levelName) has no deactivate actions"; 
        }

    }
    Log3 $hash, 1, "SECURITY disarmLevel ($name > $levelName ) disarmed!";

    readingsSingleUpdate( $hash, $levelName, 'disarmed', 1 );
    SECURITY_updateState($hash,'disarmed',$level);
}

sub SECURITY_Get($@){
	my ($hash, @param) = @_;
    my $name = shift @param;
	my $get = shift @param;
    
    if(AttrVal($name, "disable", 0 ) == 1){
        readingsSingleUpdate( $hash, "state", "disabled", 1 );
        Log3 $hash, 5, "SECURITY Set ($name) is disabled!";
        return undef;
    }else{
        Log3 $hash, 5, "SECURITY Set ($name) $name $get";
    }
    
    
    if($get =~ m/^validate/){
        my $validate = SECURITY_validateJSON($hash, SECURITY_jsonFromFile($hash));
        return Dumper($validate);
    }else{
        return "Unknown argument $get choose one of validate:noArg";
    }
}
    
sub SECURITY_Set($@){

	my ($hash, @param) = @_;
	return "\"set <SECURITY>\" needs at least one argument: \n".join(" ",keys %secCmds) if (int(@param) < 2);

    my $name = shift @param;
	my $set = shift @param;
    
    my @armFailedReason;
    
    $hash->{VERSION} = $secVersion if $hash->{VERSION} ne $secVersion;
    
    if(AttrVal($name, "disable", 0 ) == 1){
        readingsSingleUpdate( $hash, "state", "disabled", 1 );
        Log3 $hash, 3, "SECURITY Set ($name) is disabled, $set not set!";
        return undef;
    }else{
        Log3 $hash, 5, "SECURITY Set ($name) $name $set";
    }

    my $level = shift @param;
    if($set =~ m/^arm$|^disarm$/){
        if($level =~ m/^\d+$/){
            Log3 $hash, 5, "SECURITY Set ($name) input level given as digit"; 
        }else{
            Log3 $hash, 3, "SECURITY Set ($name) input level given as string $level";
            # no pretty code but works
            my $foundId;
            foreach my $levelId (0..$#{$hash->{JSON}}){
                next if $hash->{JSON}->[$levelId]->{name} ne $level;
                Log3 $hash, 3, "SECURITY Set ($name) found level ID for $level ($levelId)";
                $level = $levelId;
                $foundId = 1;
                last;
            }
            if(!$foundId){
                Log3 $hash, 1, "SECURITY Set ($name) could not find level ID for #$level#";
                return "could not find level $level ";
            }
        }
    }
    
    my $validCmds = join("|",keys %secCmds);
	if($set !~ m/$validCmds/ ) {
        return join(' ', keys %secCmds);
	
    }elsif($set =~ m/^remove/){
        SECURITY_remove($hash);
        #fixme disable device here via attr
        return undef;

    }elsif($set =~ m/^reload/){
        SECURITY_reload($hash);
        return undef;

    }elsif($set =~ m/^arm$/){
        
        if(!defined($hash->{JSON}->[$level])){
            # level not defined
            Log3 $hash, 1, "SECURITY Set ($name) cannot arm level $level, not defined"; 
        }elsif(SECURITY_getLevelStatus($hash,$level) =~ m/^armed$|^armwait$/){     #testme on silent/stateless levels
            my $levelName = $hash->{JSON}->[$level]->{name};
            Log3 $hash, 2, "SECURITY Set ($name > $levelName) already armed"; 
        }else{
            # do the actual arming
            my $levelName = $hash->{JSON}->[$level]->{name};
            Log3 $hash, 5, "SECURITY Set ($name > $levelName) arm level $level command recieved";

            if(defined($hash->{JSON}->[$level]->{configuration}->{required})){
                if(ref $hash->{JSON}->[$level]->{configuration}->{required} eq 'ARRAY' && scalar @{$hash->{JSON}->[$level]->{configuration}->{required}} eq 0){
                    Log3 $hash, 2, "SECURITY Set ($name > $levelName) $level has no requirements";
                }elsif(ref $hash->{JSON}->[$level]->{configuration}->{required} eq 'ARRAY'){
                    foreach my $reqIndex (0..$#{$hash->{JSON}->[$level]->{configuration}->{required}}){
                        my $reqName     = $hash->{JSON}->[$level]->{configuration}->{required}->[$reqIndex]->{name};
                        my $reqReading  = $hash->{JSON}->[$level]->{configuration}->{required}->[$reqIndex]->{reading};
                        my $reqValue    = $hash->{JSON}->[$level]->{configuration}->{required}->[$reqIndex]->{value};
                        Log3 $hash, 3, "SECURITY Set ($name > $levelName) needs [".$reqName.":".$reqReading."] to be $reqValue";
                        if(!defined($defs{$reqName})){
                                Log3 $hash, 2, "SECURITY Set ($name > $levelName) $reqName not found";
                        }else{
                            Log3 $hash, 5, "SECURITY Set ($name > $levelName) $reqName $reqReading ".$defs{$reqName}->{READINGS}->{$reqReading}->{VAL};
                            if($defs{$reqName}->{READINGS}->{$reqReading}->{VAL} !~ m/$reqValue/){
                                Log3 $hash, 2, "SECURITY Set ($name > $levelName) cannot arm, $reqName is not $reqValue ";
                                push @armFailedReason, "$reqName is not $reqValue";
                            }else{
                                Log3 $hash, 5, "SECURITY Set ($name > $levelName) $reqName ok";
                            }
                        }
                    }
                }
            }else{
                # level does not have a requirement
            }
        
            if(@armFailedReason){
                Log3 $hash, 1, "SECURITY Set ($name > $levelName) failed to arm due to ".join(" and ",@armFailedReason);
                if(defined($hash->{JSON}->[$level]->{configuration}->{'on-fail'})){
                
                    my $onFailAction = $hash->{JSON}->[$level]->{configuration}->{'on-fail'};
                    my $onFailReasons = join(", ",@armFailedReason);
                    $onFailAction =~ s/%reason/$onFailReasons/g;
                    Log3 $hash, 2, "SECURITY Set ($name > $levelName) ) cmd: $onFailAction"; 
                    fhem($onFailAction);
                }
                
            }else{
                Log3 $hash, 1, "SECURITY Set ($name > $levelName) armwait ".$hash->{JSON}->[$level]->{name};
                if($hash->{JSON}->[$level]->{armwait}->{delay}){ #macht eigentlich keinen sinn
                    Log3 $hash, 2, "SECURITY Set ($name > $levelName) armwait with delay ".$hash->{JSON}->[$level]->{armwait}->{delay};
                    Log3 $hash, 2, "SECURITY Set ($name > $levelName) ($name) DOES NOT WORK YET"; 
                }else{
                    Log3 $hash, 5, "SECURITY Set ($name > $levelName) immediate armwait";
                    fhem($hash->{JSON}->[$level]->{armwait}->{action}."; setreading $name ".$hash->{JSON}->[$level]->{name}." armwait");
                    SECURITY_updateState($hash,'armwait',$level);
                }

                if($hash->{JSON}->[$level]->{arm}->{delay}){
                    Log3 $hash, 2, "SECURITY Set ($name > $levelName) arm with delay ".$hash->{JSON}->[$level]->{arm}->{delay};
#fixme test multiple cmd here with ; and ;;
                    my $cmd = "defmod sec".$level."armAT at +".$hash->{JSON}->[$level]->{arm}->{delay}.'  {SECURITY_ArmLevel("'.$name.'",'.$level.')}';
                    Log3 $hash, 3, "SECURITY Set ($name > $levelName) executing $cmd";
                    fhem($cmd);

                }else{
                    SECURITY_ArmLevel($name,$level);
                }
            }
        }
        

        return undef;
    }elsif($set =~ m/^disarm$/){
        # my $level = shift @param;
        
        if(!defined($hash->{JSON}->[$level])){
            Log3 $hash, 1, "SECURITY Set ($name) level $level not defined "; 
        
        }elsif(SECURITY_getLevelStatus($hash,$level) eq 'disarmed' ){  #testme, this seems not to work for silent level
            my $levelName = $hash->{JSON}->[$level]->{name};
            SECURITY_updateState($hash,'disarmed',$level);
            Log3 $hash, 2, "SECURITY Set ($name > $levelName) already disarmed";
        }else{
            my $levelName = $hash->{JSON}->[$level]->{name};
            Log3 $hash, 5, "SECURITY Set ($name > $levelName) disarming command recieved";
            SECURITY_disarmLevel($name,$level);
        }
        return undef;
    }

}

sub SECURITY_arrayDiff {
    my %e = map { $_ => undef } @{$_[1]};
    return @{[ ( grep { (exists $e{$_}) ? ( delete $e{$_} ) : ( 1 ) } @{ $_[0] } ), keys %e ] };
}

sub SECURITY_arrayGrep {
     my ($arr,$search_for) = @_;
     return grep {$search_for eq $_} @$arr;
}

sub SECURITY_jsonFromFile {
    my $hash = shift();
    my $file = $hash->{DEF},
    my $name = $hash->{NAME};
    my $return;
    
    if( ! -e $file){
        Log3 $hash, 1, "SECURITY jsonFromFile ($name) could not read file $file"; 
    }else{
        Log3 $hash, 2, "SECURITY jsonFromFile ($name) reading $file";
        {
          local $/; #Enable 'slurp' mode
          open my $fh, "<", $file;
          $return = <$fh>;
          close $fh;
        }
        Log3 $hash, 5, "SECURITY jsonFromFile ($name) configuration loaded ".$return;
        eval {
            my $testJson = decode_json($return); 
            1;
        };
        if($@) {
            my $e = $@;
            Log3 $hash, 1, "SECURITY jsonFromFile ($name) decode_json on $file failed, please validate your JSON";
            return undef;
        };
        #return decode_json($return);
        return JSON->new->utf8(0)->decode($return);
    }
}

sub SECURITY_validateJSON {
    my $hash = shift();
    my $json = shift();
    
    my $name = $hash->{NAME};
    my  $return;
    return $return->{status} = 'failed, please install JSON::Validator' unless(eval{require JSON::Validator});

    eval
        {
        my $validator = JSON::Validator->new;
        $validator->schema(
            {
                type => "array", 
                items => {
                    type => "object", 
                    properties => {
                        "name" => { type => "string", minLength => 1, pattern => "\\D+"},
                        configuration => { 
                            type => "object",
                            properties => {
                                "on-load" => { type=> "string" , pattern => "armed|disarmed"},
                                "on-fail" => { type=> "string" },
                                required => {
                                    type => "array",
                                    items => {
                                        type => "object",
                                        properties => {
                                            "name" => {type => "string"},
                                            "reading" => {type => "string"},
                                            "value" => {type => "string"}
                                        }
                                    }
                                }

                            }
                        },
                        "sensors" => {
                            type => "array",
                            items => {
                                type => "object",
                                properties => {
                                    "name" => {type => "string", minLength => 1},
                                    "regex" => {type => "string", minLength => 1},
                                    "msg" => {type => "string"},
                                }
                            }
                        }, 
                        "actions" => { 
                            type => "array",
                            items => {
                                type => "object",
                                properties => {
                                    "name" => {type => "string", minLength => 1},
                                    "activate" => {type => "string", minLength => 1},
                                    "deactivate" => {type => "string"},
                                    "delay" => { type => "string" , pattern => "^\$|[0-9]{2}:[0-9]{2}:[0-9]{2}"}
                                }
                            }
                        },
                        "armwait" => { 
                            type => "object",
                            properties => {
                                "action" => { type => "string" },
                                "delay" => { type => "string" , pattern => "^\$|[0-9]{2}:[0-9]{2}:[0-9]{2}"}
                            }
                        },
                        "arm" => { 
                            type => "object",
                            properties => {
                                "action" => { type => "string" },
                                "delay" => { type => "string" , pattern => "^\$|[0-9]{2}:[0-9]{2}:[0-9]{2}"}
                                # no at check here
                            }
                        },
                        "disarm" => { 
                            type => "object",
                            properties => {
                                "action" => { type => "string" },
                                "delay" => { type => "string" , pattern => "^\$|[0-9]{2}:[0-9]{2}:[0-9]{2}"}
                                # no at check here
                            }
                        },
                        "armwait" => { type => "object" }
                    }
                }
            }
        );
        #print Dumper(\$validator);

#        my @errors =  $validator->validate($hash->{JSON}); #against current config
        my @errors =  $validator->validate($json); #against def file, arg2
        if(@errors){
            my $errstr;
            foreach my $errors (@errors){
                Log3 $hash, 1, "SECURITY validateJSON ($name) JSON misconfigured: " .$errors->{path} .' '. $errors->{message};
                push @{$return->{error}}, $errors->{path}.' '.$errors->{message};
            }
        }else{
            Log3 $hash, 3, "SECURITY validateJSON ($name) your JSON is valid";
            $return->{status} = 'passed';
        }
        1;
    };
    if($@) {
        my $e = $@;
        Log3 $hash, 1, "SECURITY validateJSON ($name) $e"; 
        push @{$return->{error}}, $e;
    }
    
    return $return;
    
    
}

1;

#======================================================================
#======================================================================
#
# HTML Documentation for help and commandref
#
#======================================================================
#======================================================================
=pod
=item device
=item summary    multi level JSON based alarm system
=begin html

<a name="SECURITY"></a>
<h3>SECURITY</h3>
<ul>
  <u><b>SECURITY - JSON based alarm system</b></u>
  <br>
  <br>
  blablabla<br>
  requirements:<br>
  perl JSON module<br>
  optional: JSON::Validator
  <br>
    <b>Features:</b>
  <br>
  <ul>
    <li>bla</li>
  </ul>
  <br>
  <br>
  <a name="SECURITYdefine"></a>
  <b>Define:</b>
  <ul><br>
    <code>define &lt;name&gt; SECURITY &lt;PATH-TO-YOUR-JSON&gt;</code>
    <br><br>
    example:<br>
       <code>define home SECURITY myalarm.json</code><br>
  </ul>
  <br>
  <br>
  <b>Attributes:</b>
  <ul>
    <li>"disable" - 0:1</li>
    <li>"secRoom" - &lt;room name&gt;    : optional, if set SECURITY will collect all your devices in here</li>
    <li>"secNoFile" - 0:1    : optional, if set to 1, a plain JSON can be provided in DEF</li>
  </ul>
  <br>
  <br>
  
  <a name="SECURITYreadings"></a>
  <b>Readings:</b>
  <ul>
    <li>levelx</li>
    <li>state</li>
  </ul>
  <br><br>
  <a name="SECURITYset"></a>
  <b>Set</b>
  <ul>
    <li>arm &lt;level-id-or-name&gt;  : arms a level</li>
    <li>disarm &lt;level-id-or-name&gt;   : disarms a level</li>
    <li>reload   : reload the JSON and the hole configuration</li>
    <li>remove   : removes the configuration (notifies, ats etc)</li>
  </ul>
  <br><br>
  <a name="SECURITYget"></a>
  <b>Get</b>
  <ul>
    <li><i>only works with JSON::Validator installed</i></li>
    <li>validate   : reads and validate the JSON File content against a fixed JSON schema</li>
  </ul>
  <br><br>
</ul>


=end html
=cut

