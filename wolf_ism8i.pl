#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use bignum;

use IO::Socket::INET;
use IO::Socket::Multicast; #   apt install libio-socket-multicast-perl
use Data::Dumper qw(Dumper);
use HTML::Entities;
use File::Basename;
use Math::Round qw(nearest); # apt isntall libmath-round-perl

binmode(STDOUT, ":utf8");

# Prototypen definieren: ##################################################
sub create_logdir;
sub loadConfig;
sub loadDatenpunkte;
sub writeDatenpunkteToLog;
sub showDatenpunkte;
sub add_to_log($);
sub log_msg_data($$);
sub start_IGMPserver;
sub send_IGMPmessage($);
sub start_WolfServer;
sub dec2ip($);
sub ip2dec($);
sub r_trim;
sub l_trim;
sub all_trim;
sub dbl_trim;
sub l_r_dbl_trim;

# Globale Variablen: #######################################################
my $script_path = dirname(__FILE__);
my $verbose = 1; # 0 = nichts, 1 = Telegrammauswertung, 3 = alles 
my $fw_actualize = time - 1;
my $geraet_max_length = 0;
my @datenpunkte;
my $last_auswertung = "";
my $igmp_sock;
my %hash = (
             ism8i_ip => '?.?.?.?' ,
             port     => '12004' ,
             fw       => '1.5' ,
             mcip     => '239.7.7.77' ,
             mcport   => '35353' ,
             dplog    => '0' ,
             output   => 'fhem' ,
			);

# Original Einstellungen sichern
*OLD_STDOUT = *STDOUT;
*OLD_STDERR = *STDERR;

# Umleiten von STDOUT, STDERR
create_logdir(); # Ordner 'log' erzeugen wenn nicht vorhanden.
open(my $log_fh, '>>', $script_path."/log/wolf_ism8i.log") or die "Could not open/write file 'wolf_ism8i.log' $!";
*STDOUT = $log_fh;
*STDERR = $log_fh;

add_to_log("############ Strate Wolf ISM8i Auswertungs-Modul ############\n");


#Subs aufrufen:
loadConfig();

loadDatenpunkte();

writeDatenpunkteToLog();

#showDatenpunkte();

add_to_log("");

start_IGMPserver();

start_WolfServer();

# STDOUT/STDERR wiederherstellen
*STDOUT = *OLD_STDOUT;
*STDERR = *OLD_STDERR;

#################### Sub Definitionen #####################################################################################

sub start_IGMPserver
# Startet einen Multicast Server
{
   add_to_log("# Creting multicast group server: $hash{mcip}:$hash{mcport}");

   $igmp_sock = IO::Socket::Multicast->new(
           Proto     => 'udp',
		   PeerAddr  => "$hash{mcip}:$hash{mcport}",
           ReusePort => '1',
   ) or die "ERROR: Cant create socket: $@! ";

   # ACHTUNG: kein $igmp_sock->mcast_add() bei Server!
   
   add_to_log("# Creting to multicast group success.\n");
}


sub send_IGMPmessage($)
{
   my $message = shift;
   my $ok = $igmp_sock->send($message) or die "Couldn't send to multicast group: $!";
   if ($ok == 0) { print $ok."\n"; }
}


sub start_WolfServer
#Startet einen blocking Server(Loop) an dem sich das Wolf ISM8i Modul verbinden und seine Daten schicken kann. 
{
   # auto-flush on socket
   $| = 1;
 
   # creating a listening socket
   my $socket = new IO::Socket::INET (
      LocalHost => '0.0.0.0',
      LocalPort => $hash{port},
      Proto => 'tcp',
      Listen => 5,
      Reuse => 1
   );
   die "Cannot create socket $!\n" unless $socket;
   add_to_log("Server wartet auf ISM8i Verbindung auf Port $hash{port}");
 
   # waiting for a new client connection
   my $client_socket = $socket->accept();
 
   # get information about a newly connected client
   my $client_address = $client_socket->peerhost();
   $hash{ism8i_ip} = $client_address;
   my $client_port = $client_socket->peerport();
   add_to_log("Verbindung eines ISM8i Moduls von $client_address:$client_port");
 
   while(1)
      {
       # read up to 4096 characters from the connected client
       my $rec_data = "";
       $client_socket->recv($rec_data, 4096);
	   
       dprint("Daten Empfang (".length($rec_data)." Bytes):\n");
       dprint(join(" ", unpack("H2" x length($rec_data), $rec_data))."\n");
	   
	   my $starter = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
       my @fields = split(/$starter/, $rec_data);
       foreach my $r (@fields)
	      {
		   if (length($r) > 0)
		     {
		      $r = $starter.$r;
	     
              # Falls ein SetDatapointValue.Req gesendet wurde wird mit einem SetDatapointValue.Res als Bestätigung geantwortet.
              my $send_data = create_answer($r);
	          if (length($send_data) > 0) { $client_socket->send($send_data); }
			  
	          decodeTelegram($r);
         	 }	 
		  }
      }
   dprint("-----------------------------------------------------------------------------------\n");

   # notify client that response has been sent
   shutdown($client_socket, 1);

   $socket->close();
}


sub create_answer($)
#Erzeugt ein SetDatapointValue.Res Telegramm das an das ISM8i zurückgeschickt wird.
{
   my @h = unpack("H2" x length($_[0]), $_[0]);
   
   if (length($_[0]) < 14)
      {
	   return "";
	  }
   elsif ($h[10] eq "f0" and $h[11] eq "06")
      {
       my @a = ($h[0],$h[1],$h[2],$h[3],"00","11",$h[6],$h[7],$h[8],$h[9],$h[10],"86",$h[12],$h[13],"00","00","00");
       dprint("Antwort: ".join(" ", @a)."\n");
       return pack("H2" x 17, @a);
	  }
   else
      {
	   return "";
	  }
}


sub create_logdir
# Erstellt den Ordner für Logs.
{
   my $log_ordner = $script_path."/log";
   if (not (-e "$log_ordner")) {
      my $ok = mkdir("$log_ordner",0755);
      if ($ok == 0) { die "Could not create dictionary '$log_ordner' $!"; }
   }
}


sub log_msg_data($$)
# Loggt die als Multicast versendeten Daten in ein Logfile.
{
   my ($msg,$format) = @_;
   my $filename = $script_path."/log/wolf_data.log";
   open(my $fh, '>>:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";
   
   if ($format eq 'fhem') {
      print $fh getLoggingTime()." $msg\n";
   } elsif ($format eq 'csv') {
      print $fh getLoggingTime().";$msg\n";
   }
   
   close $fh;
}


sub add_to_log($)
#fügt einen Eintrag zur Logdatei hinzu
{
   my $msg = shift;
   my $filename = $script_path."/log/wolf_ism8i.log";
   open(my $fh, '>>:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";
   print $fh getLoggingTime()." $msg\n";
   close $fh;
}


sub getLoggingTime
#Returnt eine gut lesbare Zeit für Logeinträge.
{
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime(time);
    my $nice_timestamp = sprintf ("%04d.%02d.%02d %02d:%02d:%02d", $year+1900,$mon+1,$mday,$hour,$min,$sec);
    return $nice_timestamp;
}


###############################################################
# this sub converts a decimal IP to a dotted IP
sub dec2ip($) { join '.', unpack 'C4', pack 'N', shift; }

###############################################################
# this sub converts a dotted IP to a decimal IP
sub ip2dec($) { unpack N => pack CCCC => split /\./ => shift; }

###############################################################
### Whitespace (v.a. CR LF) rechts im String löschen

sub r_trim { my $s = shift; $s =~ s/\s+$//; return $s; }

###############################################################
### Whitespace links im String löschen

sub l_trim { my $s = shift; $s =~ s/^\s+//; return $s; }

###############################################################
### Allen Whitespace im String löschen

sub all_trim { my $s = shift; $s =~ s/\s+//g; return $s; }

###############################################################
### Doppelten Whitespace im String durch ein Leezeichen ersetzen

sub dbl_trim { my $s = shift; $s =~ s/\s+/ /g; return $s; }

###############################################################
### r_trim, l_trim, dbl_trim zusammen auf einen String anwenden

sub l_r_dbl_trim { my $s = shift; my $r = l_trim(r_trim(dbl_trim($s))); return $r; }


sub max($$) { $_[$_[0] < $_[1]]; }

sub min($$) { $_[$_[0] > $_[1]]; }


sub getFhemFriendly($)
#Ersetzt alle Zeichen so, dass das Ergebnis als FHEM Reading Name taugt.
{
my $working_string = shift;
my @tbr = ("ö","oe","ä","ae","ü","ue","Ö","Oe","Ä","Ae","Ü","Ue","ß","ss","³","3","²","2","°C","C","%","proz","[[:punct:][:space:][:cntrl:]]","_","___","_","__","_","^_","","_\$","");

for (my $i=0; $i <= scalar(@tbr)-1; $i+=2)
  {
   my $f = $tbr[$i];
   if ($working_string =~ /$f/)
      {
       my $r = $tbr[$i+1];
	   $working_string =~ s/$f/$r/g;
	  }
   }
return $working_string;
}


sub decodeTelegram($)
#Telegramme entschlüsseln und die entsprechenden Werte zur weiteren Entschlüsselung weiterreichen an sub getCsvResult
{
   my $TelegrammLength = length($_[0]);
   my @h = unpack("H2" x $TelegrammLength, $_[0]);
   
   my $hex_result = join(" ", @h);
   dprint($hex_result."\n");
 
   my $FrameSize = hex($h[4].$h[5]);
   my $MainService = hex($h[10]);
   my $SubService = hex($h[11]);
   
   if ($FrameSize != $TelegrammLength) {
	  if ($verbose >= 1) { add_to_log("*** ERROR: TelegrammLength/FrameSize missmatch. [".$FrameSize."/".$TelegrammLength."] ***"); }
   } elsif ($SubService != 0x06) {
	  if ($verbose >= 1) { add_to_log("*** WARNING: No SetDatapointValue.Req. [".sprintf("%x", $SubService)."] ***"); }
   } elsif ($MainService == 0xF0 and $SubService == 0x06) {
      my $StartDatapoint = hex($h[12].$h[13]);
      my $NumberOfDatapoints = hex($h[14].$h[15]);
	  my $Position = 0;
	  
	  for (my $n=1; $n <= $NumberOfDatapoints; $n++) {
         my $DP_ID = hex($h[$Position + 16].$h[$Position + 17]);
         my $DP_command = hex($h[$Position + 18]);
         my $DP_length = hex($h[$Position + 19]);
         my $v = "";
		 my $send_msg = "";
         for (my $i=0; $i <= $DP_length - 1; $i++) { $v .= $h[$Position + 20 + $i]; }
         my $DP_value = hex($v);
	     my $auswertung =  getLoggingTime.";".getCsvResult($DP_ID, $DP_value);
		 if ($auswertung ne $last_auswertung) {
			$last_auswertung = $auswertung;
			 
			my @fields = split(/;/, $auswertung); # [0]=Timestamp, [1]=DP ID, [2]=Geraet, [3]=Datenpunkt, [4]=Wert, optional [5]=Einheit
			 
			if ($hash{output} eq 'fhem') {
			   ## Auswertung für FHEM erstellen ##
	           $send_msg = getFhemFriendly($fields[2]).".".$fields[1].".".getFhemFriendly($fields[3]); # Geraet - DP ID - Datenpunkt
			   if (scalar(@fields) == 6) { $send_msg .= ".".getFhemFriendly($fields[5]); } # Einheit (wenn vorhanden)
			   $send_msg .= " ".$fields[4]; # Wert (nach Leerstelle!)
			} elsif ($hash{output} eq 'csv') {
			   ## Auswertung als CSV erstellen ##
	           $send_msg = $fields[1].";".$fields[2].";".$fields[3].";".$fields[4];
			   if (scalar(@fields) == 6) { $send_msg .= ";".$fields[5]; }
			}

			## Auswertung an Multicast Gruppe schicken ..
			send_IGMPmessage($send_msg);
			
			## Wenn aktiviert, Auswertung in ein File schreiben ##
			if ($hash{dplog} eq '1') { log_msg_data($send_msg,$hash{output}); }
			 
			## Wolf ISMi basierte Werte alle 60 Minuten schicken ##
			if (time >= $fw_actualize and $hash{output} eq 'fhem') { 
			   send_IGMPmessage("ISM8i.997.IP $hash{ism8i_ip}");
			   send_IGMPmessage("ISM8i.998.Port $hash{port}");
			   send_IGMPmessage("ISM8i.999.Firmware $hash{fw}");
			   $fw_actualize = time + 3600;
			}	
		 }
		 $Position += 4 + $DP_length;
	  }
   }
}


sub loadConfig
#Config Datei laden und Werte zwischenspeichern. Wenn keine Config Datei vorhanden ist wird eine angelegt.
#Wenn die Werte in der Config nicht den Vorgaben entsprechen, dann werden die Standardwerte genommen. 
#
#Bedeutung der Einträge der Config:
#   ism8i_port = Port auf dem das Modul auf den TCP Trafic des Wolf ISM8i Schnittstellenmoduls hört.
#                Die IP und der Port wird im Webinterface des Schnittstellenmoduls eingestellt. Die IP
#                ist die IP des PCs/Raspis auf dem dieses Modul läuft.
#                Default ist 12004.
#   fw_version = Die Firmware Version des Wolf ISM8i Schnittstellenmoduls. Diese steht im Webinterface des Schnittstellenmoduls.
#                Möglich sind 1.4 oder 1.5.
#                Default ist 1.5.
#   multicast_ip = die IPv4 Adresse der Multicast Gruppe an der die die entschlüsselten Datagramme geschickt werden. Default ist 
#                  Bitte beim Ändern auf die Vorgaben für Multicast Adressen achten!
#                  Default ist 239.7.7.77.
#   multicast_port = Der Port der Multicast Gruppe. Möglich von 1 bis 65535.
#                    Default ist 35353.
#   dp_log = Gibt an ob die empfangenen Datenpunkte als Log ausgegeben werden sollnen.
#            Wenn geloggt wird bitte in regelmäßigen Abständen die Größe des Logfiles prüfen und ggf. löschen, dader Log schnell sehr groß werden kann.
#            Möglich sind 0 oder 1.
#            Default ist 0.
#   output = Das Format in welchem die Datenpunkte an die Multicast Gruppe oder an das Datenpunkte-Log gesickt wird. 
#            Möglich ist 'csv' für das CSV Format (mit Semikolon (;) separiert) z.B. zum Importieren in Tabekkenkalkulationen. 
#            Möglich ist 'fhem' als Spezialformat für das ISM8I Modul.
#            Default ist 'fhem'.
#
{
   my $file = $script_path."/wolf_ism8i.conf";
   add_to_log("Reading Config:");
   if (-e $file) {
      open(my $data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";
      add_to_log("   Config file '$file' found and opened for reading.");
      while (my $line = <$data>) {
	    $line = lc($line); # alles lowe case
		if ($line !~ m/#/) {
		   my @fields = split(/ /, l_r_dbl_trim($line));
	       if (scalar(@fields) == 2) {
              add_to_log("      $fields[0] -> $fields[1]");
	          if ($fields[0] eq "ism8i_port") { 
		         if ($fields[1] =~ m/^([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$/ and $fields[1] > 0 and $fields[1] <= 65535) {
			        $hash{port} = $fields[1]; } else { $hash{port} = '12004'; }
		      } elsif ($fields[0] eq "fw_version") {
		         if ($fields[1] =~ m/^\d{1}\.\d{1}$/) {
		         $hash{fw} = $fields[1]; } else { $hash{fw} = '1.5'; }
			     if ($hash{fw} ne '1.4') { $hash{fw} = '1.5'; }
		      } elsif ($fields[0] eq "multicast_ip") {
     		     if ($fields[1] =~ m/^(?:(?:\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])\.){3}(?:\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])$/) {
		         $hash{mcip} = $fields[1]; } else { $hash{mcip} = '239.7.7.77'; }
		      } elsif ($fields[0] eq "multicast_port") {
		         if ($fields[1] =~ m/^([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$/ and $fields[1] > 0 and $fields[1] <= 65535) {
			        $hash{mcport} = $fields[1]; } else { $hash{mcport} = '35353'; }
		      } elsif ($fields[0] eq "dp_log") {
		         if ($fields[1] =~ m/^(1|0)$/) {
		            $hash{dplog} = $fields[1]; } else { $hash{dplog} = '0'; }
		      } elsif ($fields[0] eq "output") {
		         if ($fields[1] =~ m/^(csv|fhem)$/) {
		            $hash{output} = $fields[1]; } else { $hash{dplog} = 'fhem'; }
	          }
		   }	  
	    }
      }
   } else {
     add_to_log("   Config file not found, creating new config file.");
     open(my $fh, '>:encoding(UTF-8)', $file) or die "Could not open/write file '$file' $!";
	  
     print $fh "######################################################################################################################################################\n";
     print $fh "#Config Datei laden und Werte zwischenspeichern. Wenn keine Config Datei vorhanden ist wird eine angelegt.\n";
     print $fh "#Wenn die Werte in der Config nicht den Vorgaben entsprechen, dann werden die Standardwerte genommen.\n";
     print $fh "######################################################################################################################################################\n";
     print $fh "#Bedeutung der Einträge der Config:\n";
     print $fh "#\n";
     print $fh "#   ism8i_port = Port auf dem das Modul auf den TCP Trafic des Wolf ISM8i Schnittstellenmoduls hört.\n";
     print $fh "#                Die IP und der Port wird im Webinterface des Schnittstellenmoduls eingestellt. Die IP\n";
     print $fh "#                ist die IP des PCs/Raspis auf dem dieses Modul läuft.\n";
     print $fh "#                Default ist 12004.\n";
     print $fh "#   fw_version = Die Firmware Version des Wolf ISM8i Schnittstellenmoduls. Diese steht im Webinterface des Schnittstellenmoduls.\n";
     print $fh "#                Möglich sind 1.4 oder 1.5\n";
     print $fh "#                Default ist 1.5\n";
     print $fh "#   multicast_ip = die IPv4 Adresse der Multicast Gruppe an der die die entschlüsselten Datagramme geschickt werden. Default ist\n";
     print $fh "#                  Bitte beim Ändern auf die Vorgaben für Multicast Adressen achten!\n";
     print $fh "#                  Default ist 239.7.7.77.\n";
     print $fh "#   multicast_port = Der Port der Multicast Gruppe. Möglich von 1 bis 65535.\n";
     print $fh "#                    Default ist 35353.\n";
     print $fh "#   dp_log = Gibt an ob die empfangenen Datenpunkte als Log ausgegeben werden sollnen.\n";
     print $fh "#            Wenn geloggt wird bitte in regelmäßigen Abständen die Größe des Logfiles prüfen und ggf. löschen, dader Log schnell sehr groß werden kann.\n";
     print $fh "#            Möglich sind 0 oder 1.\n";
     print $fh "#            Default ist 0.\n";
     print $fh "#   output = Das Format in welchem die Datenpunkte an die Multicast Gruppe oder an das Datenpunkte-Log gesickt wird.\n";
     print $fh "#            Möglich ist 'csv' für das CSV Format (mit Semikolon (;) separiert) z.B. zum Importieren in Tabekkenkalkulationen.\n";
     print $fh "#            Möglich ist 'fhem' als Spezialformat für das ISM8I Modul.\n";
     print $fh "#            Default ist 'fhem'\n";
     print $fh "######################################################################################################################################################\n";
     print $fh "\n";
	 
	 print $fh "ism8i_port $hash{port}\n";
	 print $fh "fw_version $hash{fw}\n";
	 print $fh "multicast_ip $hash{mcip}\n";
	 print $fh "multicast_port $hash{mcport}\n";
	 print $fh "dp_log $hash{dplog}\n";
	 print $fh "output $hash{output}\n";

     close $fh;
   }
	
   add_to_log("      [$hash{port}] [$hash{fw}] [$hash{mcip}] [$hash{mcport}] [$hash{dplog}] [$hash{output}]");
}


sub loadDatenpunkte
#Datenpunkte aus einem CSV File (Semikolon-separiert) laden.
#Die Reihenfolge der CSV Spalten lautet: DP ID, Gerät, Datenpunkt KNX-Datenpunkttyp, Output/Input, Einheit
#Die einzelnen CSV Felder dürfen keine Kommas, Leerstellen oder Anführungszeichen enthalten.
{
   #erstmal vorsichtshalber datenpunkte array löschen:
   while(@datenpunkte) { shift(@datenpunkte); }
   
   my $fw_version = $hash{fw};
   $fw_version =~ s/\.//g;
   my $file = $script_path."/wolf_datenpunkte_".$fw_version.".csv";

   open(my $data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";

   while (my $line = <$data>)
    {
     my @fields = split(/;/, r_trim($line));
	 if (scalar(@fields) == 6)
	   {
	    $datenpunkte[0 + $fields[0]] = [ @fields ]; # <-so hinzufügen, damit der Index mit der DP ID übereinstimmt zu einfacheren Suche.
		$geraet_max_length = max($geraet_max_length, length($fields[1]));
	   }
    }
}


sub showDatenpunkte
#Devloper Sub zur Kontrolle des eingelesenen CSV Files
{
   print "\n";
   foreach my $o (@datenpunkte) {
	  foreach my $i (@$o) { print $i."  "; }
	  print "\n";
   }
}


sub writeDatenpunkteToLog
#Devloper Sub zur Kontrolle des eingelesenen CSV Files
{
   my $filename = $script_path."/log/wolf_ism8i_datenpunkte.log";
   open(my $fh, '>:encoding(UTF-8)', $filename) or die "Could not open file '$filename' $!";
   print $fh "\n";
   foreach my $o (@datenpunkte)
     {
	  foreach my $i (@$o) { print $fh $i."  "; }
	  print $fh "\n";
	 }
   close $fh;
}


sub getDatenpunkt($$)
#Returnt aus dem 2D Array mit Datenpunkten den Datenpunkt als Array mit der übergebenen DP ID.
#$1 = DP ID , $2 = Index des Feldes (0 = DP ID, 1 = Gerät, 2 = Datenpunkt, 3 = KNX-Datenpunkttyp, 4 = Output/Input, 5 = Einheit)
{
   my $d = $datenpunkte[$_[0]][$_[1]];
   if ( (defined $d) and (length($d)>0) ) { return $d; } else { return "ERR:NotFound"; } 
}


sub getCsvResult($$)
#Berchnet den Inhalt des Telegrams und gibt das Ergebnis im CSV Mode ';'-separiert.
#$1 = DP ID , $2 = DP Value
#Ergebnis: DP_ID [1]; Gerät [2]; Erignis [3]; Wert [4]; Einheit [5] (falls vorhanden)
{
   my $dp_id = $_[0];
   my $dp_val = $_[1];
   my $geraet = getDatenpunkt($dp_id, 1);
   my $ereignis = getDatenpunkt($dp_id, 2);
   my $datatype = getDatenpunkt($dp_id, 3);
   my $result = $dp_id.";".$geraet.";".$ereignis.";";
   my $v = "ERR:NoResult";
   
   if ($datatype eq "DPT_Switch") 
     {
	  if ($dp_val == 0) {$v = "Aus";} elsif ($dp_val == 1) {$v = "An";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Bool") 
     {
	  if ($dp_val == 0) {$v = "Falsch";} elsif ($dp_val == 1) {$v = "Wahr";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Enable") 
     {
	  if ($dp_val == 0) {$v = "Deaktiviert";} elsif ($dp_val == 1) {$v = "Aktiviert";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_OpenClose") 
     {
	  if ($dp_val == 0) {$v = "Offen";} elsif ($dp_val == 1) {$v = "Geschlossen";}
	  $result .= $v;
	 }
   elsif ($datatype eq "DPT_Scaling") 
     {
	  $result .= nearest(0.01, ($dp_val & 0xff) * 100 / 255).";%";
	 }
   elsif ($datatype eq "DPT_Value_Temp") 
     {
	  $result .= pdt_knx_float($dp_val).";°C";
	 }
   elsif ($datatype eq "DPT_Value_Tempd") 
     {
	  $result .= pdt_knx_float($dp_val).";K";
	 }
   elsif ($datatype eq "DPT_Value_Pres") 
     {
	  $result .= pdt_knx_float($dp_val).";Pa";
	 }
   elsif ($datatype eq "DPT_Power") 
     {
	  $result .= pdt_knx_float($dp_val).";kW";
	 }
   elsif ($datatype eq "DPT_Value_Volume_Flow") 
     {
	  $result .= pdt_knx_float($dp_val).";l/h";
	 }
   elsif ($datatype eq "DPT_TimeOfDay") 
     {
	  $result .= pdt_time($dp_val);
	 }
   elsif ($datatype eq "DPT_Date") 
     {
	  $result .= pdt_date($dp_val);
	 }
   elsif ($datatype eq "DPT_FlowRate_m3/h") 
     {
	  $result .= (pdt_long($dp_val) * 0.0001).";m³/h";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy") 
     {
	  $result .= pdt_long($dp_val).";Wh";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy_kWh") 
     {
	  $result .= pdt_long($dp_val).";kWh";
	 }
   elsif ($datatype eq "DPT_HVACMode") 
     {
	  my @Heizkreis = ("Standby","Automatikbetrieb","Heizbetrieb","Sparbetrieb");
	  my @CWL = ("Automatikbetrieb","Reduzierung Lüftung","Nennlüftung");
	 
      if ($geraet =~ /Heizkreis/ or $geraet =~ /Mischerkreis/)
	   	{ $v = $Heizkreis[$dp_val]; }
	  elsif ($geraet =~ /CWL/)
	   	{ $v = $CWL[$dp_val]; }
      
	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_DHWMode") 
     {
	  my @Warmwasser = ("Standby","Automatikbetrieb","Dauerbetrieb");

      if ($geraet =~ /Warmwasser/) { $v = $Warmwasser[$dp_val]; }

	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_HVACContrMode") 
     {
	  my @CGB2_MGK2_TOB = ("Test","Start","Frost Heizkreis","Frost Warmwasser","Schornsteinferger","Kombibetrieb","Parallelbetrieb","Warmwasserbetrieb",
	                       "Warmwassernachlauf","Mindest-Kombizeit","Heizbetrieb","Nachlauf Heizkreispumpe","Frostschutz","Standby","Kaskadenbetrieb",
						   "GLT-Betrieb","Kalibration","Kalibration Heizbetrieb","Kalibration Warmwasserbetrieb","Kalibration Kombibetrieb");

      my @BWL1S = ("ODU Test","Test","Frostschutz HK","Frostschutz Warmwasser","Durchfluss gering","Vorwärmung","Abtaubetrieb","Antilegionellenfunktion",
	               "Warmwasserbetrieb","WW-Nachlauf","Heizbetrieb","HZ-Nachlauf","Aktive Kühlung","Kaskade","GLT","Standby","Pump down");
				   
	  if ($geraet =~ /CGB-2/ or $geraet =~ /MGK-2/ or $geraet =~ /TOB/)
	    { $v = $CGB2_MGK2_TOB[$dp_val]; }
	  elsif ($geraet =~ /BWL-1-S/)
	   	{ $v = $BWL1S[$dp_val]; }

	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
	else
	 {
	  $result .= "ERR:TypeNotFound[".$datatype."]";
	 }

   return $result;   
}

sub pdt_knx_float($)
{
# Format: 
#   2 octets: F16
#   octet nr: 2MSB 1LSB
#   field names: FloatValue
#   encoding: MEEEEMMMMMMMMMMM
# Encoding: 
#   Float Value = (0,01*M)*2**(E)
#   E = [0...15]
#   M = [-2048...2047], two‘s complement notation
#   For all Datapoint Types 9.xxx, the encoded value 7FFFh shall always be used to denote invalid data.
# Range: [-671088,64...670760,96]
# PDT: PDT_KNX_FLOAT
#
   my $val = $_[0];
   my $sign = ($val & 0x8000) >> 15;
   my $exp = ($val & 0x7800) >> 11;
   my $mant = $val & 0x07ff;
   if ($sign != 0) { $mant = -(~($mant - 1) & 0x7ff); } 
   return (1 << $exp) * 0.01 * $mant;
}


sub pdt_long($)
{
   my $val = $_[0] % 0xffffffff;
   return ($val > 2147483647 and $val - 2147483648 or $val);
}


sub pdt_time($)
{
# 3 Byte Time
# DDDHHHHH RRMMMMMM RRSSSSSS
# R Reserved
# D Weekday
# H Hour
# M Minutes
# S Seconds
   my $b1 = ($_[0] & 0xff0000) >> 16;
   my $b2 = ($_[0] & 0x00ff00) >> 8;
   my $b3 = ($_[0] & 0x0000ff);
   my $weekday = ($b1  & 0xe0) >> 5;
   my @weekdays = ["","Mo","Di","Mi","Do","Fr","Sa","So"];
   my $hour = $b1 & 0x1f;
   my $min = $b2 & 0x3f;
   my $sec = $b3 & 0x3f;
   return sprintf("%s %d:%d:%d", $weekdays[$weekday], $hour, $min, $sec);
}

sub pdt_date($)
{
# 3 byte Date
# RRRDDDDD RRRRMMMM RYYYYYYY
# R Reserved
# D Day
# M Month
# Y Year
   my $b1 = ($_[0] & 0xff0000) >> 16;
   my $b2 = ($_[0] & 0x00ff00) >> 8;
   my $b3 = ($_[0] & 0x0000ff);
   my $day = $b1 & 0x1f;
   my $mon = $b2 & 0xf;
   my $year = $b3 & 0x7f;
   if ($year < 90) { $year += 2000; } else { $year += 1900; }
   return sprintf("%02d.%02d.%04d", $day, $mon, $year);
}

sub getBitweise($$$)
#Berechnet aus einer Zahl eine Zahl anhand der vorgegebenen Bits.
#$1 = Zahl, $2 = Startbit, $3 = Endbit
{
   my $start_bit = $_[1];
   my $end_bit = $_[2];
   my $val = $_[0] >> $start_bit - 1;
   my $mask = 0xffffffff >> (32 - ($end_bit - $start_bit +1));
   my $result = $val & $mask;
   return $result;
}


sub dprint($)
#Printet die übergebene Variable nur wenn debuged wird.
{
   if ($verbose == 2) { print ($_[0]); }
}