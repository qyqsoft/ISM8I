#!/usr/bin/perl

use strict;
use warnings;
use utf8;

my $geraet = "Heizgerät 1 (TOB,CGB-2,MGK-2)";
my $dp_val = 23;
my $v = "";
my $result = $geraet." ---> ".$dp_val." ---> ";

my @CGB2_MGK2_TOB = ("Test","Start","Frost Heizkreis","Frost Warmwasser","Schornsteinferger","Kombibetrieb","Parallelbetrieb","Warmwasserbetrieb",
	                       "Warmwassernachlauf","Mindest-Kombizeit","Heizbetrieb","Nachlauf Heizkreispumpe","Frostschutz","Standby","Kaskadenbetrieb",
						   "GLT-Betrieb","Kalibration","Kalibration Heizbetrieb","Kalibration Warmwasserbetrieb","Kalibration Kombibetrieb");
						   
print scalar(@CGB2_MGK2_TOB)."\n";			   

my @BWL1S = ("ODU Test","Test","Frostschutz HK","Frostschutz Warmwasser","Durchfluss gering","Vorwärmung","Abtaubetrieb","Antilegionellenfunktion",
	               "Warmwasserbetrieb","WW-Nachlauf","Heizbetrieb","HZ-Nachlauf","Aktive Kühlung","Kaskade","GLT","Standby","Pump down");
				   
print scalar(@BWL1S)."\n";			   

if ($geraet =~ /Heizgerät 1/)
   { $v = $CGB2_MGK2_TOB[$dp_val]; }
elsif ($geraet =~ /BWL-1-S/)
  	{ $v = $BWL1S[$dp_val]; }

if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_val."]";}

print $result."\n\n";

print getFhemFriendly(",,,Heizgerät 1 (TOB,CGB-2,MGK-2)");

print "\n\n";

sub getFhemFriendly($)
{
my $b = $_[0];
#my @tbr = (" / ","_"," ","_",".","_","/","_",";","_","ö","oe","ä","ae","ü","ue","Ö","Oe","Ä","Ae","Ü","Ue","ß","ss","³","3","²","2","°C","C","%","proz");

my @tbr = ("-","","ö","oe","ä","ae","ü","ue","Ö","Oe","Ä","Ae","Ü","Ue","ß","ss","³","3","²","2","°C","C","%","proz","[[:punct:][:space:][:cntrl:]]","_","___","_","__","_","^_","","_\$","");

for (my $i=0; $i <= scalar(@tbr)-1; $i+=2)
  {
   my $f = $tbr[$i];
   #print $f." # ";
   if ($b =~ /$f/)
      {
       my $r = $tbr[$i+1];
	   #$b = join( $r, split($r, $b) );
	   $b =~ s/$f/$r/g;
	  print "Match -> [".$f."] zu [".$r."] witd: ".$b."\n";
	  }
   }
return $b;
}
