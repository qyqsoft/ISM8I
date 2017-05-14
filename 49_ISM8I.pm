#!/usr/bin/perl

#######################################################################################################
#  49_ISM8I.pm
# 
#  (C) 2017 Copyright: Dr. Mugur Dietrich
#   E-Mail: m punkt i punkt dietrich at gmx punkt de
#
#  Beschreibung:
#  Das Schnittstellenmodul ISM8i ist ausschließlich in Verbindung mit Wolf Heizgeräten
#  und Wolf Zubehör einzusetzen. Mit dem Schnittstellenmodul ISM8i kann der Nutzer Datenpunkte von
#  Wolf-System-Komponenten selbstständig per Ethernet verarbeiten. 
#  Die Datenpunkte des Moduls nimmt mein Modul ism8i.pl, welches bereits laufen muss, entgegen 
#  und verarbeitet die Rohdaten zu Menschen- und FHEM- lesbaren Daten und stellt sie als Logfile 
#  und als Multicast Stream im lokalen netzwerk zur verfügung
#
#  Voraussetzungen:
#  Diese und das ism8i.pl Modul benötigen:
#  - Perl Modul: IO::Socket::Multicast 
#      Auf Debian Systemen wird es mit "apt install libio-socket-multicast-perl" installiert.
#  - Perl Modul: Math::Round
#      Auf Debian Systemen wird es mit "apt install libmath-round-perl" installiert.
#  
#
#######################################################################################################

package main;

use strict;
use warnings;
use utf8;
use IO::Socket;
use IO::Socket::Multicast;

###############################################################

sub ISM8I_Initialize($);
sub ISM8I_Define($$);
sub ISM8I_Undef($$);
sub ISM8I_Delete;
sub ISM8I_Attr;
sub ISM8I_Set($@);
sub ISM8I_Read($);
sub r_trim;
sub l_trim;
sub all_trim;
sub dbl_trim;
sub l_r_dbl_trim;
sub find_reading_on_dp($$);
sub socket_connect($);
sub socket_disconnect($);


###############################################################
#                  ISM8I Initialize
###############################################################
sub ISM8I_Initialize($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};

  $hash->{ReadFn}     = "ISM8I_Read";
  $hash->{DefFn}      = "ISM8I_Define";
  $hash->{UndefFn}    = "ISM8I_Undef";
  $hash->{DeleteFn}   = "ISM8I_Delete";
  $hash->{SetFn}      = "ISM8I_Set";
  $hash->{AttrFn}     = "ISM8I_Attr";
  $hash->{AttrList}   = "adress_ip ".
						"adress_port ".
						"ignoreDatapoints ".
                        "timeout ".
						$readingFnAttributes;
  
}


###############################################################
#                  ISM8I Define
###############################################################
sub ISM8I_Define($$) {
  my ($hash, $def) = @_;
  my $name = $hash->{NAME};
  
  $hash->{HELPER}{LASTUPDATE}    = time();
  $hash->{HELPER}{DEFAULT_IP}    = '239.7.7.77';
  $hash->{HELPER}{DEFAULT_PORT}  = '35353';
  
  # Default Atribute setzen falls Atribute leeer oder nicht vorhanden:
  if (AttrVal($name, "adress_ip", "empty") eq "empty") { $attr{$name}{"adress_ip"} = "239.7.7.77"; }
  if (AttrVal($name, "adress_port", "empty") eq "empty") { $attr{$name}{"adress_port"} = "35353"; }
  if (AttrVal($name, "timeout", "empty") eq "empty") { $attr{$name}{"timeout"} = "60"; }
  if (AttrVal($name, "event-on-change-reading", "empty") eq "empty") { $attr{$name}{"event-on-change-reading"} = ".*"; }

  socket_connect($hash);

return undef;
}


###############################################################
#                  ISM8I Undefine
###############################################################
sub ISM8I_Undef($$) {
  my ($hash, $arg) = @_;
  socket_disconnect($hash);
  
  readingsSingleUpdate($hash, "state", "closed", 1);
return undef;
}


###############################################################
#                  ISM8I Delete
###############################################################
sub ISM8I_Delete {
    my ($hash, $arg) = @_;
    my $index = $hash->{TYPE}."_".$hash->{NAME}.".*";
    
    # gespeicherte Energiezählerwerte löschen
    setKeyValue($index, undef);
return undef;
}


###############################################################
#                  ISM8I Attr
###############################################################
sub ISM8I_Attr {
  my ($cmd,$name,$aName,$aVal) = @_;
  my $hash = $defs{$name};
  my $do;
  my $dp;
  my $reading;
  my $i = 0;
  my $mem_ip = $hash->{IP};
  my $mem_port = $hash->{PORT};
  my @datapoints;
  
  # $cmd  - Vorgangsart - kann die Werte "del" (löschen) oder "set" (setzen) annehmen
  # $name - Gerätename
  # $aName / $aVal sind Attribut-Name und Attribut-Wert
  
  if ($aName ne "ignoreDatapoints") {
	  $_[3] = all_trim($aVal); # Alle Whitespaces entfernen.
      $aVal = $_[3]; 
  }

  if ($aName eq "adress_ip") {
      unless ($aVal =~ m/^(?:(?:\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])\.){3}(?:\d|[1-9]\d|1\d\d|2[0-4]\d|25[0-5])$/) { 
	     return "$aName: $aVal ist keine gueltige IPv4 Adresse!"; }
      if ($cmd eq "set" and $aVal ne "$mem_ip") {
          $hash->{IP} = $aVal;
          socket_disconnect($hash);
      } elsif ($cmd eq "del") {
	     return "$aName: Attribut '$aName' kann nicht gelöscht werden!";
      }
  }
  
  if ($aName eq "adress_port") {
      unless ($aVal =~ m/^([0-9]{1,4}|[1-5][0-9]{4}|6[0-4][0-9]{3}|65[0-4][0-9]{2}|655[0-2][0-9]|6553[0-5])$/ and $aVal > 0 and $aVal <= 65535) {
         return "$aName: $aVal ist keine gueltige Port-Angabe!"; }
      if ($cmd eq "set" and $aVal ne "$mem_port") {
          $hash->{PORT} = $aVal;
          socket_disconnect($hash);
      } elsif ($cmd eq "del") {
	     return "$aName: Attribut '$aName' kann nicht gelöscht werden!";
      }
  }
  
  if ($aName eq "ignoreDatapoints" and length($aVal) > 0) {
	  $_[3] = l_r_dbl_trim($aVal); # Alle doppelte Leerzeichen/Tabs entfernen.
      $aVal = $_[3]; 
	  Log3 ($name, 5, "Ignore Atribute: $aVal");

      @datapoints = split(/ /, $aVal);
	  foreach $dp (@datapoints) {
	    if ($dp !~ m/^\d{1,3}$/) { return "$aName: $dp entspricht nicht den Vorgaben der Ignore Liste!"; }
		$i ++;
      }
	  
      if ($cmd eq "set" and $i > 0) {
	      readingsSingleUpdate($hash, "Ignores_Count", "$i", 1); # Anzahl der Ignores angeben
		  foreach $dp (@datapoints) { 
            $reading = find_reading_on_dp($hash, $dp);
			if ( defined($reading) ) { fhem("deletereading $name $reading");; }
		  }
      } elsif ($cmd eq "del") {
	      readingsSingleUpdate($hash, "Ignores_Count", "0", 1); # Anzahl der Ignores angeben
	  }
  }
  
  return undef;
}


###############################################################
#                  ISM8I Set
###############################################################
sub ISM8I_Set($@) {
  my ( $hash, $name, $cmd, @args ) = @_;
  
  my %sets = ("reset" => "noArg", "connect" => "noArg", "disconnect" => "noArg");

#Beispiele für Set Einstellungen : 
# my %sets = ("text" => "", "clear" => "noArg", "display" => "on,off", "cursor" => "", "scroll" => "left,right");
# und dann: return "Unknown argument $args[1], choose one of " . join(" ", @commands);


  if (!defined($sets{$cmd})) {
  	my @commands = ();
    foreach my $key (sort keys %sets) {
      push @commands, $sets{$key} ? $key.":".join(",",$sets{$key}) : $key;
    }
    return "Unknown argument $args[1], choose one of " . join(" ", @commands);
  }
  
  if ($cmd =~ m/^reset/) {
    socket_disconnect($hash);
    socket_connect($hash);
   }
  if ($cmd =~ m/^connect/) {
    socket_connect($hash);
   }
  if ($cmd =~ m/^disconnect/) {
    socket_disconnect($hash);
   }

  return undef;
}


###############################################################
#                  ISM8I Read (Hauptschleife)
###############################################################
# called from the global loop, when the select for hash->{FD} reports data
sub ISM8I_Read($) {
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $socket = $hash->{TCPDev};
  my $timeout = AttrVal($name, "timeout", 60);
  my $data;
  my $dp_number;
  my $ignores;
  my $t;
  my @fields;
  my @dp_fields;
  $fields[0] = "";
  $fields[1] = "";
  $dp_fields[0] = "";
  
  return if(IsDisabled($name));
  
  return unless $socket->recv($data, 1024); # Liest verarbeitete Wolf ISM8i Daten von Multicast Quelle.
  
  if ( length($data) > 0 and $data !~ m/^\d{1,3}\;.*\;.*/) {
     Log3 ($name, 5, $name." received: ".$data);
	 
	 @fields = split(/ /, l_r_dbl_trim($data));
	 $ignores = AttrVal($name, "ignoreDatapoints", "");
	 $t = 0;

	 if (scalar(@fields) == 2) {
       if ($fields[0] eq "ISM8i.997.IP") {
		  $hash->{WOLF_IP} = $fields[1];
		  $t = 1;
	   } elsif ($fields[0] eq "ISM8i.998.Port") {
		  $hash->{WOLF_COMPORT} = $fields[1];
		  $t = 1;
	   } elsif ($fields[0] eq "ISM8i.999.Firmware") {
		  $hash->{WOLF_FIRMWARE} = $fields[1];
		  $t = 1;
	   }
	   if ($t == 0) {	   
	      if (length($ignores) <= 0) {
             readingsSingleUpdate($hash, "$fields[0]", "$fields[1]", 1); 
	      } else {
	         @dp_fields = split(/\./, $fields[0]);
		     if (scalar(@dp_fields) >= 3) {
 	            Log3 ($name, 5, "Checking Ignore: *$dp_number* not in * $ignores * -> ".(" $ignores " !~ m/\Q$dp_number/));
	            if (" $ignores " !~ m/\Q$dp_number/) { readingsSingleUpdate($hash, "$fields[0]", "$fields[1]", 1); }
			 }
		  }
	   }
	 
	   # Anzahl Ignores angeben
	   if (length($ignores) <= 0) { $t = 0 } else { $t = scalar(split(/ /, $ignores)); }
	   readingsSingleUpdate($hash, "Ignores_Count", "$t", 1);

	   # LastUpdate festhalten und Zeitdiff in den State
	   $t = ReadingsTimestamp($name, "$fields[0]", TimeNow);
	   $hash->{HELPER}{LASTUPDATE} = time();
	   readingsSingleUpdate($hash, "Readings_LastUpdate", "$t", 1);

	   # Anzahl der Readings in den Status:
	   $t = scalar(keys ($hash->{READINGS})) - 4;
	   readingsSingleUpdate($hash, "Readings_Count", "$t", 1);
	 }
  }
  
return undef;
}


###############################################################
#                  Hilfsroutinen
###############################################################

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



###############################################################
### Schreibt alle vorhandenen Readings ins Log (Developement only)

sub find_reading_on_dp($$) {
  my ($hash, $find) = @_;
  if ($find !~ m/^\d{1,3}$/) { return undef; }
  
  #my $regx = "^$find\\..*"; 
  my $regx = "^.*\\.$find\\..*"; # /^.*\.\d{1,3}\..*/

  my $r;
  
  foreach $r ( keys $hash->{READINGS} ) { 
    #Log3 ("MyWolf", 5, "Search reading: $find -> $regx -> $r");

    if ($r =~ m/$regx/) { 
	  #Log3 ("MyWolf", 5, "*** Reading found: $find -> $r ***");
	  return $r; 
	}
  }
  
  return undef;  
}


###############################################################
###  Verbindung trennen und Socket löschen

sub socket_disconnect($) {
  my $hash = shift;
  my $name = $hash->{NAME};
  my $socket = $hash->{TCPDev};
  
  if ( !defined($socket) ) { return undef; }
  
  Log3 ($name, 3, "Closing multicast socket...");
  $socket->mcast_drop($hash->{IP});
  
  my $ret = close($hash->{TCPDev});
  Log3 ($name, 3, "Closeed connection: $ret");
  delete($hash->{TCPDev});
  delete($selectlist{"$name"});
  delete($hash->{FD});
  
  readingsSingleUpdate($hash, "state", "disconnected", 1);

  return undef;
}


###############################################################
###  Socket erzeugen und Multicastgruppe beitreten

sub socket_connect($) {
  my $hash = shift;
  my $name= $hash->{NAME};
  my $def_err = "";

  $hash->{IP}   = AttrVal($name, "adress_ip", '239.7.7.77');
  $hash->{PORT} = AttrVal($name, "adress_port", '35353');
  
  my $socket = IO::Socket::Multicast->new(
           Proto     => 'udp',
           LocalPort => $hash->{PORT},
           ReuseAddr => '1',
           ReusePort => defined(&ReusePort) ? 1 : 0,
  ) or $def_err .= "ERROR: Cant create socket: $@! ";
  
  $socket->mcast_add($hash->{IP}) or $def_err .= "ERROR: Couldn't set group: $@!";

  if ($def_err ne "") {
  	 readingsSingleUpdate($hash, "state", "Socket Error", 1);
     Log3 ($name, 3, "ERROR: $def_err");
	 return "ISM8I $name $def_err";
  } else {
  	 readingsSingleUpdate($hash, "state", "initialized", 1);
     Log3 ($name, 3, "Socket initialized");
	 
     $hash->{TCPDev}= $socket;
     $hash->{FD} = $socket->fileno();
     delete($readyfnlist{"$name"});
     $selectlist{"$name"} = $hash;
	 return undef;
  }
  
  return undef;
}
 
1;


=pod
=item summary Integration vom Wolf ISM8i Schnittstellenmodul
=begin html

<a name="ISM8I"></a>
<h3>ISM8I</h3>
  <ul>
    Erstellt 2017 von Dr. Mugur Dietrich.
	<br>
	Details in meinem Blog <b><a>http://www.tips-und-mehr.de</a></b>
	<br>
	Files in meinem Git Hub <b><a>https://github.com/qyqsoft/ISM8I</a></b>
	<br><br><br>
    <b>Zitat aus der Wolf Montage- und Bedienungsanleitung:</b>
	<br><br>
    ISM8i - eBus / Ethernet-Schnittstelle
	<br><br>
    Mit dem Schnittstellenmodul ISM8i kann der Nutzer Datenpunkte von Wolf-System-Komponenten selbstständig per Ethernet verarbeiten.
    Dazu muss softwaretechnisch zunächst eine Verbindung zum Schnittstellenmodul aufgebaut werden. IP-Adressen für ISM8i und den Kommunikationspartner können
    über eine Weboberfläche vergeben werden. Anschließend sind die Daten über das spezielle „TCP/IP-Protokoll mit integriertem ObjectServer-Telegramm“ auszuwerten.
	<br><br>
	<b>Voraussetzungen</b>
	<br><br>
	Um das FHEM Modul ISM8I in Betrieb zu nehmen braucht einige Vorarbeit. Das Wolf ISM8i Schnittstellenmodul schickt verschlüsselte Datagramme als TCP Pakete an eine 
	im Modul-Webinterface vorher eingestellte IP Adresse und erwartet dann eine spezielle verschlüsselte Antwort. Weiterhin ist eine Datenpunkt-spezifische Auswertung 
	angelehnt an die KNX Variablen Codierung nötig um die Datagramme zu entschlüsseln. Da diese Prozeduren Rechnerzeit beanspruchen und der TCP Verbindungen 'blocking' sind
	würde die direkte Integration in ein FHEM Modul Die Ausführung von FHEM verlangsamen oder ganz stoppen. Deswegen habe ich mich entschlossen die ganzen Rechnereien und 
	und die TCP Komunikation in ein externes Mudul auszulagern, welches vorab installiert werden muss.
	<br><br>
	Das Wolf ISM8i Schnittstellenmodul sollte eine Firmware Version 1.5 oder höher haben. Die Firma Wolf updatet die Firmware kostenlos nach Kontaktaufnahme und Einsendung 
	des Moduls. Frühere FW Versionen gehen evtl auch, nur kann es sein dass diverse Datagramme eurer Geräte gar nicht erst erzeugt und gesendet werden bzw. falsch sind. Bei 
	der FW Version 1.4 gab es 191, bei der FW Version 1.5 gibt es 210 Datenpunkte und es sind nicht nur welche dazu gekommen, es haben sich auch etliche verändert. Ihr könnt aber 
	im Configfile meines externen ism8i.pl Moduls angeben welche FW version ihr habt und es werden die entsprechenden Datenpunkte verwendet. 
	Weiterhin sind folgende Perl Module nötig:
	<br><br>
     - Perl Modul: IO::Socket::Multicast. Auf Debian Systemen mit <code>apt install libio-socket-multicast-perl</code> installieren.
	<br><br>
     - Perl Modul: Math::Round. Auf Debian Systemen mit <code>apt install libmath-round-perl</code> installieren.
	<br><br>
	<b>Umsetzung</b>
	<br><br>
	Das externe ism8i.pl Modul schickt die entschlüsselten Datagramme an eine Multicast Gruppe, die das ISM8I FHEM Modul abfängt und als Reading ausgibt.<br>
	Obwohl das Wolf ISM8i Schnittstellenmodul auch Eingaben verarbeiten kann habe ich mich entschlossen dass das ISM8I FHEM Modul ausschliesslich lesend auf die Schnittstelle 
    zugreift, da ich bein Testen gelegentlich das Steuermodul unserer Wolf Brennwertheizung in einen Fehlerzustand ("Adaptation kann nicht geladen werden" o.ä.) gebracht habe 
	und sich die Anlage nur mittels Aus- und Einschalten wieder eingekriegt hat.
	<br><br>
	Die empfangenen Daten sind follgendermaßen aufgebaut:
	<br><br>
	Es wird ein String empfangen der aus verschiedenen Bestandteilen besteht die mit einem Punkt (.) verbunden sind.<br>
	Das sieht z.B. so aus: <b>Heizgeraet_1_TOB_CGB_2_MGK_2.1.Stoerung</b> oder <b>Mischermodul_1.115.Warmwassertemperatur.C</b>.
	<br><br>
	Die Bedeutung der einzelnen Bestandteile ist:<br>
	<ul>
    <li>Teil 1 : Die Bezeichnung des Gerätes welches die Daten schickt. </li>
    <li>Teil 2 : Die Nummer/ID das Datenpunkts. </li>
    <li>Teil 3 : Der Bestandteil des Gesrätes welches die Daten schickt. </li>
    <li>Teil 4 : Die Einheit des übertragenen Wertes. Teil 4 ist optional ung kommt nicht bei allen Datenpnkten vor.<br>
                 Die Bedeutung der Enheiten lautet: C = °C, proz = %, Pa = Pascal, l_h = Liter/Stunde, m3_h = Kubikmeter/Stunde etc.</li> 
    </ul>
	<br><br>
	
  </ul>  
<a name="ISM8Idefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; ISM8I </code><br>
    <br>
    Definiert ein Wolf ISM8i Schnittstellenmodul (ISM8I). 
  </ul>  
  <br><br>
  
<a name="ISM8Iattr"></a>
<b>Attribute</b>
<ul>
  <li><b>adress_ip</b>               : Die IP Adresse der Multicast-Gruppe an die das ism8i.pl Modul Daten sendet. </li>
  <li><b>adress_port</b>             : Der Port der Multicast-Gruppe an die das ism8i.pl Modul Daten sendet. </li>
  <li><b>event-on-change-reading</b> : Sollte mit .* gesetzt sein um nur Änderungen abzupassen, da sehr viele Daten geschickt werden. </li>
  <li><b>ignoreDatapoints</b>        : Eine Liste von ganzen 1-3 stelligen Zahlen durch Leerzeichen getrennt. Alle in der List enthaltenen Datapoints werden 
                                       ignoriert und nicht weiter als Reading verarbeitet.<br>
								       Bereits bestehende Readings mit dem Eintrag in die Liste werden gelöscht.<br>
									   Wenn 'ignoreDatapoints' gelöscht wird dauert es eine Weile bis die entsprechenden Datagramme ankommen 
									   und alle zuvor gelöschten Datenpunkte sind wieder hergestellt. </li>
  <li><b>timeout</b>                 : Gibt die Zeit in Sekunden an nach dem letzten Empfang eines Datapoints. Wenn diese überschritten wird geht der Status auf 'timeout'.<br>
                                       Ist z.Z. im Code noch nicht umgesetzt! </li> 

  <br><br>
  Achtung:
  <br><br>
  Nach Änderungen an <b>adress_ip</b> oder <b>adress_port</b> geht der Modul Status auf 'disconnected' und der Datenempfang wird unterbrochen und muss mit 
  <code>set MeinModul connect</code> wieder aktiviert werden! 
</ul>

<br><br><br>
  
=end html

=cut
