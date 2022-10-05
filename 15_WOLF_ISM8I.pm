#!/usr/bin/perl
#
#  $Id: 15_WOLF_ISM8I.pm 
#######################################################################################################
#  WOLF_ISM8I
# 
#  Erstellt von: Dr. Mugur Dietrich
#  E-Mail: m punkt i punkt dietrich at gmx punkt de
#
#  Beschreibung:
#  FHEM Modul zur Komunikation mit dem Wolf Informations- und Schnittstellenmodul ISM8i.
#
#######################################################################################################

package main;

use strict;
use warnings;
use utf8;
use IO::Socket;
use IO::Socket::INET;
use threads;
use Thread::Queue;
use DevIo;

sub WOLF_ISM8I_Initialize($);
sub WOLF_ISM8I_Define($$);
sub WOLF_ISM8I_Undef($@);
sub WOLF_ISM8I_Read($);
sub WOLF_ISM8I_Set($@);
sub WOLF_ISM8I_Get($$@);
sub WOLF_ISM8I_Attr($@); 

sub WOLF_ISM8I_TimeoutFunction($); 

sub _ISM8I_TcpServerOpen($$);
sub _ISM8I_TcpServerAccept($$);
sub _ISM8I_TcpServerClose($@);
sub _ISM8I_ClientSocketClose($);
sub _ISM8I_TcpCommunicationThread;
sub _ISM8I_TimerStartOrUpdate($);
sub _ISM8I_TimerKill($);

sub _ISM8I_create_answer($@);
sub _ISM8I_dataToHex($);
sub _ISM8I_enqueReadings($$);
sub _ISM8I_decodeThreadTelegram($@);
sub _ISM8I_sendToThread($$);
sub _ISM8I_countWolfReadings($);
sub _ISM8I_deleteIgnores($);
sub _ISM8I_loadDatenpunkte;
sub _ISM8I_loadSetter;
sub _ISM8I_getSetterWidget($$);
sub _ISM8I_dec2ip($);
sub _ISM8I_ip2dec($);
sub _ISM8I_r_trim;
sub _ISM8I_l_trim;
sub _ISM8I_al_l_trim;
sub _ISM8I_db_l_trim;
sub _ISM8I_l_r_db_l_trim;
sub _ISM8I_find_reading_on_dp($$); 

sub _ISM8I_getFhemFriendly($);
sub _ISM8I_getFhemInOut($);
sub _ISM8I_getDatenpunkt($$);
sub _ISM8I_getCsvResult($$);

sub _ISM8I_codeSetting($$);
sub _ISM8I_codeValueByType($$);
sub _ISM8I_convert_NumberToChars($$);
sub _ISM8I_getLen($);

sub _ISM8I_convert_DptFloatToNumber($);
sub _ISM8I_convert_NumberToDptFloat($);
sub _ISM8I_convert_DptLongToNumber($);
sub _ISM8I_convert_DptScalingToNumber($);
sub _ISM8I_convert_NumberToDptScaling($);

sub _ISM8I_convert_DptTimeToString($);
sub _ISM8I_convert_StringToDptTime_DayOnly($);
sub _ISM8I_convert_StringToDptTime_TimeOnly($);
sub _ISM8I_convert_DptDateToString($);
sub _ISM8I_convert_StringToDptDate($);

sub _ISM8I_getBitweise($$$);
sub _ISM8I_setBitwise($$$);
sub _ISM8I_getByteweise($$);


###############################################################
#                  Globale Variablen
###############################################################

my @datenpunkte;
my @writepunkte;
my %sets;
my @clients = ();
my $dataQueue = Thread::Queue->new();
my $_ISM8I_sendToThreadQueue = Thread::Queue->new();
my $qSplitter = chr(0x02).chr(0x03).chr(0x04);

 
###############################################################
#                  WOLF_ISM8I_Initialize
###############################################################
sub WOLF_ISM8I_Initialize($) 
{
  my ($hash) = @_;

  $hash->{DefFn}      = "WOLF_ISM8I_Define";
  $hash->{UndefFn}    = "WOLF_ISM8I_Undef";
  $hash->{ReadFn}     = "WOLF_ISM8I_Read";
  $hash->{SetFn}      = "WOLF_ISM8I_Set";
  $hash->{AttrFn}     = "WOLF_ISM8I_Attr";
  $hash->{GetFn}      = "WOLF_ISM8I_Get";

  #$hash->{ReadyFn}    = "WOLF_ISM8I_Ready";
  #$hash->{WriteFn}    = "WOLF_ISM8I_Write";
  
  $hash->{CanAuthenticate} = 0;
  
  
  #Attribute für WOLF_ISM8I_Attr
  no warnings 'qw';
  my @attrList = qw(
    ignoreDatapoints
	showDebugData:0,1
	forewardAddress
  );
  use warnings 'qw';
  $hash->{AttrList} = join(" ", @attrList)." ".$readingFnAttributes;
 
  _ISM8I_loadDatenpunkte; # Läd ./FHEM/wolf_datenpunkte_15.csv
  _ISM8I_loadSetter; # Läd ./FHEM/wolf_writepunkte_15.csv
}


###############################################################
#                  WOLF_ISM8I_Define
###############################################################
sub WOLF_ISM8I_Define($$)
{
  my ($hash, $def) = @_;
  my ($name, $type, $port) = split("[ \t]+", $def);
  return "Usage: define <name> WOLF_ISM8I tcp-portnr>" if($port !~ m/^\d+$/);
  
  # Default Attribute setzen falls Attribute leeer oder nicht vorhanden:
  if (AttrVal($name, "showDebugData", "empty") eq "empty") { $attr{$name}{"showDebugData"} = "0"; }
  if (AttrVal($name, "event-on-change-reading", "empty") eq "empty") { $attr{$name}{"event-on-change-reading"} = ".*"; }

  WOLF_ISM8I_Undef($hash, undef) if($hash->{OLDDEF}); # modify
  my $ret = _ISM8I_TcpServerOpen($hash, $port);

  # Make sure that fhem only runs once
  if($ret && !$init_done) {
    Log3 $name, 1, "$ret. Exiting.";
    exit(1);
  }
  $hash->{clients} = {};
  $hash->{retain} = {};

  _ISM8I_deleteIgnores($hash);

  return $ret;
}


###############################################################
#                  WOLF_ISM8I_Undef
###############################################################
sub WOLF_ISM8I_Undef($@)
{
   my ($hash, $arg) = @_;
  
   foreach ( @clients ) { 
      $_->kill('KILL')->detach;
      if( $_->is_joinable() ) { $_->join(); } 
   }

   _ISM8I_TimerKill($hash);

   my $ret = _ISM8I_TcpServerClose($hash);
   my $sname = $hash->{SNAME};
   return undef if(!$sname);

   my $shash = $defs{$sname};
   delete($shash->{clients}{$hash->{NAME}});

   return $ret;
}
  

###############################################################
#                  WOLF_ISM8I_Read
###############################################################
sub WOLF_ISM8I_Read($)
{
   my ($hash) = @_;
   my $name = $hash->{NAME};
   
   if (ReadingsVal($name, "_WOLF_READINGS_COUNT", 0) == 0) {
      readingsSingleUpdate($hash, "_WOLF_READINGS_COUNT", _ISM8I_countWolfReadings($hash), 1);
   }

   if( $hash->{SERVERSOCKET} ) { 
     _ISM8I_TimerStartOrUpdate($hash);
     push ( @clients, threads->create(\&_ISM8I_TcpCommunicationThread, $hash) );
     foreach ( @clients ) { if( $_->is_joinable() ) { $_->join(); } }
   }
	
   return;
}


###############################################################
#                  WOLF_ISM8I_TimeoutFunction
###############################################################
#Ist die Hauptfunktion zum anzeigen der Readings die im Thread 
#enqued wurden. Durch den InternalTimer aufgerufen. Verarbeitet 
#die Readings aus dem Thread.
###############################################################
sub WOLF_ISM8I_TimeoutFunction($) 
{
   my ($hash) = @_;
   my $name = $hash->{NAME};
   my ($deq, @field, $rc, $nc);
   my $upd = 0;
   my $ts = undef;

   while ($dataQueue->pending() > 0) {
      $deq = $dataQueue->dequeue_nb();
   	  @field = split(/$qSplitter/, $deq);
	 
	  if (scalar(@field) == 2) { 
	     readingsSingleUpdate($hash, "$field[0]", "$field[1]", 1); 
	     if ( ($field[0] !~ m/^_/) and ($field[0] ne "state") ) { $ts = TimeNow; $upd = 1; }
	  } 
   } 

   if ($upd == 1) { 
      # Anzahl der Wolf Readings ermitteln und ggf aktualisieren:
	  $rc = ReadingsVal($name, "_WOLF_READINGS_COUNT", 0);
	  $nc = _ISM8I_countWolfReadings($hash);
	  if ($nc != $rc) { 
	     readingsSingleUpdate($hash, "_WOLF_READINGS_COUNT", "$nc", 1); 
	  }
  
      # Timestamp des letzten Wolf Readings:
      if ($ts) { 
	    readingsSingleUpdate($hash, "_WOLF_LAST_READING", "$ts", 1); 
	  }
   }
  
   _ISM8I_TimerStartOrUpdate($hash); # hier am Ende stehen lassen!!!
}


###############################################################
#                  WOLF_ISM8I_Set
###############################################################
sub WOLF_ISM8I_Set($@)
{
   my ( $hash, $name, $cmd, @args ) = @_;
   my $arg = join("", @args);
   my $settings = join(" ", sort keys %sets);
   my $id = 0;   
   if ($cmd =~ /(\.)(\d{1,3})(\.)/) { $id = $2; }
   
   return "\"set $name\" needs at least one argument" unless (defined($cmd));
   return "Unknown argument '$cmd', choose one of $settings" unless (index($settings, $cmd) >= 0);

   if ($id > 0 and defined($arg)) {
      my $val = _ISM8I_codeSetting($id, $arg);
      if (length($val) > 0) { 
         Log3 ($name, 5, "WOLF_ISM8I_Set: cmd -> $cmd / id -> $id / arg -> $arg");
         Log3 ($name, 5, "send telegram -> "._ISM8I_dataToHex($val));
         _ISM8I_sendToThread("sendDatagramm", $val); 
	  }
   }
}


###############################################################
#                  WOLF_ISM8I_Get
###############################################################
sub WOLF_ISM8I_Get($$@)
{
   my ( $hash, $name, $opt, @args ) = @_;
 
   my %gets = ( 
     "ClearReadings:noArg"  => "noArg",
     "GetAllData:noArg"     => "noArg",
     "Reconnect:noArg"      => "noArg",
   );

   if ($opt eq "ClearReadings") {
      fhem("deletereading $name .*");; 
   }
   elsif ($opt eq "GetAllData") {
      my $getAll = chr(0x06).chr(0x20).chr(0xf0).chr(0x80).chr(0x00).chr(0x16).chr(0x04).chr(0x00).chr(0x00).chr(0x00).chr(0xf0).chr(0xd0);
      _ISM8I_sendToThread("sendDatagramm", $getAll); 
   }
   elsif($opt eq "Reconnect") {
	  my $port = $hash->{PORT};
      WOLF_ISM8I_Undef($hash, undef);
      _ISM8I_TcpServerOpen($hash, $port);
   }
   else {
	 return "Unknown argument $opt, choose one of " . join(" ", keys %gets)
   }
  
   return undef; 
}


###############################################################
#                  WOLF_ISM8I_Attr
###############################################################
sub WOLF_ISM8I_Attr($@)
{
  my ($cmd,$name,$aName,$aVal) = @_;
  my $hash = $defs{$name};
  my $dp;
  my $reading;
  my $i = 0;
  my @datapoints;
  
  # $cmd  - Vorgangsart - kann die Werte "del" (löschen) oder "set" (setzen) annehmen
  # $name - Gerätename
  # $aName / $aVal sind Attribut-Name und Attribut-Wert
  
  if ($aName eq "ignoreDatapoints" and length($aVal) > 0) {
	  $_[3] = _ISM8I_l_r_db_l_trim($aVal); # Alle doppelte Leerzeichen/Tabs entfernen.
      $aVal = $_[3]; 
	  Log3 ($name, 5, "Ignore Attribute: $aVal");

      @datapoints = split(/ /, $aVal);
	  foreach $dp (@datapoints) {
	    if ($dp !~ m/^\d{1,3}$/) { return "$aName: $dp entspricht nicht den Vorgaben der Ignore Liste!"; }
		$i ++;
      }
	  
      if ($cmd eq "set" and $i > 0) {
	      readingsSingleUpdate($hash, "_WOLF_IGNORES_COUNT", "$i", 1); # Anzahl der Ignores angeben
		  foreach $dp (@datapoints) { 
            $reading = _ISM8I_find_reading_on_dp($hash, $dp);
			if ( defined($reading) ) { fhem("deletereading $name $reading");; }
		  }
      } elsif ($cmd eq "del") {
	      readingsSingleUpdate($hash, "_WOLF_IGNORES_COUNT", "0", 1); # Anzahl der Ignores angeben
	  }
  }
   
  if ($aName eq "showDebugData") {
     if (($cmd eq "set" and $aVal == 0) or $cmd eq "del"){ 
	    fhem("deletereading $name _DBG.*");
		_ISM8I_sendToThread("showDebugData", 0);
	 }
  }
  
  if ($aName eq "forewardAddress") {
	 if ($cmd eq "set" and length($aVal) > 0) {
	    $_[3] = _ISM8I_al_l_trim($aVal); # Alle Whitespaces entfernen.
        $aVal = $_[3]; 
        _ISM8I_sendToThread("forewardAddress", $aVal);
      } elsif ($cmd eq "del") {
		_ISM8I_sendToThread("forewardAddress", "none");
	  }
  }
  
  return undef
}

#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#   Subs and Functions   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

###############################################################
#                  _ISM8I_TcpServerOpen
###############################################################
sub _ISM8I_TcpServerOpen($$)
{
  my ($hash, $port) = @_;
  my $name = $hash->{NAME};
  my @opts = (
      LocalHost => "0.0.0.0",
      LocalPort => $port,
      Proto     => "tcp",
      Listen    => 32,
      ReuseAddr => 1
  );	#  Blocking  => 1,

  
  readingsSingleUpdate($hash, "state", "Initialized", 0);
  
  $hash->{SERVERSOCKET} = IO::Socket::INET->new(@opts);

  if(!$hash->{SERVERSOCKET}) {
    return "$name: Can't open server port at $port: $!";
  }

  $hash->{SERVERSOCKET}->autoflush(1);
  $hash->{FD} = $hash->{SERVERSOCKET}->fileno();
  $hash->{PORT} = $hash->{SERVERSOCKET}->sockport();

  $selectlist{"$name.$port"} = $hash;
  Log3 $hash, 3, "$name: port ". $hash->{PORT} ." opened";
  return undef;
}


###############################################################
#                  _ISM8I_TcpServerAccept
###############################################################
sub _ISM8I_TcpServerAccept($$)
{
  my ($hash, $type) = @_;
  my $name = $hash->{NAME};

  my @clientinfo = $hash->{SERVERSOCKET}->accept();
  if(!@clientinfo) {
    Log3 $name, 3, "Accept failed ($name: $!)" if($! != EAGAIN);
    return undef;
  }
  
  #$clientinfo[0]->blocking(0);  # Forum #24799
  
  $hash->{CONNECTS}++;

  my ($port, $iaddr) = sockaddr_in($clientinfo[1]);
  my $caddr = inet_ntoa($iaddr);
  my $cname = "${name}_${caddr}_${port}";
  my %nhash;
  
  $nhash{NR}    = $devcount++;
  $nhash{NAME}  = $cname;
  $nhash{PEER}  = $caddr;
  $nhash{PORT}  = $port;
  $nhash{FD}    = $clientinfo[0]->fileno();
  $nhash{CD}    = $clientinfo[0];     # sysread / close won't work on fileno
  $nhash{TYPE}  = $type;
  $nhash{SNAME} = $name;
  $nhash{TEMPORARY} = 1;              # Don't want to save it
  $nhash{BUF}   = "";
  
  readingsSingleUpdate($hash, "state", "Connected", 0);
  
  $attr{$cname}{room} = "hidden";
  $defs{$cname} = \%nhash;
  $selectlist{$nhash{NAME}} = \%nhash;

  my $ret = $clientinfo[0]->setsockopt(SOL_SOCKET, SO_KEEPALIVE, 1);

  Log3 $name, 4, "Connection accepted from $nhash{NAME}";
  return \%nhash;
}


###############################################################
#                  _ISM8I_TcpServerClose
###############################################################
sub _ISM8I_TcpServerClose($@)
{
  my ($hash, $dodel) = @_;
  my $name = $hash->{NAME};

  if(defined($hash->{CD})) { # Clients
    close($hash->{CD});
    delete($hash->{CD}); 
    delete($selectlist{$name});
    delete($hash->{FD});  # Avoid Read->Close->Write
    delete $attr{$name} if($dodel);
    delete $defs{$name} if($dodel);
  }
  
  if(defined($hash->{SERVERSOCKET})) {          # Server
    close($hash->{SERVERSOCKET});
    $name = $name . "." . $hash->{PORT};
    delete($selectlist{$name});
    delete($hash->{FD});  # Avoid Read->Close->Write
  }
    
  return undef;
}

#**************************************************************
###############################################################
#                  _ISM8I_TcpCommunicationThread
###############################################################
#**************************************************************
sub _ISM8I_TcpCommunicationThread
{
  my $hash = shift;
  my $name = $hash->{NAME};
  
  my $nhash = _ISM8I_TcpServerAccept($hash, "WOLF_ISM8I");
  my $client_socket = $nhash->{CD};
  return "Client socked creation failed." if(!$client_socket);

  $client_socket->autoflush(1);
  my $csname = $client_socket->peerhost().":".$client_socket->peerport();

  Log3 $name, 4, "$name: Connected to $csname";
  _ISM8I_enqueReadings("state", "Connected");

  my ($data, $ret_read, @fields, $forewardsocket, $answ, @answers, $ret_write, $r, $f_recbuf, $msg);
  my ($deq, @deqfields, $qcommand, $qvalue);
  my $showDebug = AttrVal($name, "showDebugData", 0);
  my $forewardAddress = AttrVal($name, "forewardAddress", "none");
  my $starter = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
  $hash->{DeviceName} = "";
	
  #Einmalig alle Werte vom ISM8i anfordern (06 20 F0 80 00 16 04 00 00 00 F0 D0):
  my $getAll = chr(0x06).chr(0x20).chr(0xf0).chr(0x80).chr(0x00).chr(0x16).chr(0x04).chr(0x00).chr(0x00).chr(0x00).chr(0xf0).chr(0xd0);
  syswrite($client_socket, $getAll);
  
  while(1) {	
    $ret_read = sysread($client_socket, $data, 50000); # <<<=== HIER WERDEN DIE DATAGRAMME GELESEN !!!
	
	#Telegramm beantworten und weiterverarbeiten:
    if (defined($ret_read) and defined($data) and length($data) > 0) {
       Log3 $name, 5, "$name: data read -------> "._ISM8I_dataToHex($data);
       
	   @answers = @{ _ISM8I_create_answer($name, $data) };
	   
	   while (scalar(@answers) > 0) {
	      $answ = shift(@answers);
		  
          if ( length($answ) > 0 ) { 
	         $ret_write = syswrite($client_socket, $answ);  # <<<=== HIER WERDEN DIE DATAGRAMME QUITTIERT !!!
		  
             if ($showDebug) {
                _ISM8I_enqueReadings("_DBG_SENT_BYTES", $ret_write);
                _ISM8I_enqueReadings("_DBG_SENT_DATA", _ISM8I_dataToHex($answ));
		     }
		  }
	   }

       eval { _ISM8I_decodeThreadTelegram($name, $data); }; # <<<=== HIER WERDEN DIE DATAGRAMME AUSGEWERTET !!! 'eval' für Fehler abfangen
	 }	

    if ($showDebug) {
       _ISM8I_enqueReadings("_DBG_SOCKET", $client_socket);
       _ISM8I_enqueReadings("_DBG_CLIENT_ADDRESS", $csname);
       _ISM8I_enqueReadings("_DBG_RECEIVED_BYTES", $ret_read);
       _ISM8I_enqueReadings("_DBG_RECEIVED_DATA", _ISM8I_dataToHex($data));
    }
		 
	#Falls Forewardadresse festgelegt, dann Daten weiterschicken:
    if ( $forewardAddress ne "none" ) {
       my $fwhash = $hash;			 
	   $fwhash->{DeviceName} = $forewardAddress; 
	   my $err = DevIo_OpenDev($fwhash, undef,  undef, undef);
			
	   if (defined($err)) { 
          Log3 $name, 3, "$name: Foreward error: $err";
       } else {
	      my $epoc = time();
	      do { } until (DevIo_IsOpen($fwhash) or (time() - $epoc >= 2)); # Wartet auf offene Verbindung oder bricht nach 2 Sekunden ab.
	      if (DevIo_IsOpen($fwhash)) {
             Log3 $name, 5, "$name: Foreward IO-Objekt: ". DevIo_IsOpen($fwhash);
	         DevIo_SimpleWrite($fwhash, $data, 0); 
	         DevIo_CloseDev($fwhash);
	      }
	   }
    } 

    #Daten aus dem Haupt-Thread verarbeiten:
    while ($_ISM8I_sendToThreadQueue->pending() > 0) {
        $deq = $_ISM8I_sendToThreadQueue->dequeue_nb();
	    Log3 ($name, 5, "$name: _ISM8I_sendToThreadQueue->dequeue: "._ISM8I_dataToHex($deq));

        if (!defined($deq)) { $deq = " $qSplitter $qSplitter "; }
        @deqfields = split(/$qSplitter/, $deq);
	 
	    if (scalar(@deqfields) == 2) { 
	       $qcommand = $deqfields[0];
		   $qvalue = $deqfields[1]; 
	       if ($qcommand eq "showDebug") { $showDebug = $qvalue; }
	       if ($qcommand eq "forewardAddress") { $forewardAddress = $qvalue; }
	       if ($qcommand eq "sendDatagramm") { 
		      syswrite($client_socket, $qvalue); 
			  Log3 ($name, 3, "$name: Datagramm transmited -> "._ISM8I_dataToHex($qvalue));
              if ($showDebug) { _ISM8I_enqueReadings("_DBG_SEND_DATAGRAMM_DATA", _ISM8I_dataToHex($qvalue)); }
		   }
	    } 
    } 
  }

  shutdown($client_socket, 2);
  $client_socket->close(); 
  delete($selectlist{$nhash->{NAME}});
  delete($nhash->{FD});
  
  _ISM8I_enqueReadings("state", "Diconnected");
	
  # Client has exited so thread should exit too
  threads->exit();
  return;
}


#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~


###############################################################
#                  _ISM8I_TimerStartOrUpdate
###############################################################
#Startet oder updatet den InternalTimer 
###############################################################
sub _ISM8I_TimerStartOrUpdate($) 
{
  my ($hash) = @_;
  my $name = $hash->{NAME};
  my $tout = 1; # Sekunden für den Timeout
  
  RemoveInternalTimer($hash);
  InternalTimer(gettimeofday() + $tout, "WOLF_ISM8I_TimeoutFunction", $hash);
}


###############################################################
#                  _ISM8I_TimerKill
###############################################################
#Löscht den InternalTimer 
###############################################################
sub _ISM8I_TimerKill($) 
{
  my ($hash) = @_;
  RemoveInternalTimer($hash);
}


###############################################################
#                  getUniq
###############################################################
sub splitTelegrams($)
{
   my $data = shift;
   my $splitter = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
   my @oldfields = split(/$splitter/, $data);
   my (@newfields, %hash, @unique);
   
   foreach my $t (@oldfields) { 
      if ($t ne $splitter and length($t) > 0) { push(@newfields, $splitter.$t); } 
   }
   
   %hash = map { $_ => 1 } @newfields;
   @unique = keys %hash;

   return \@unique;	
}	   


###############################################################
#                  _ISM8I_create_answer
###############################################################
#Erzeugt ein SetDatapointValue.Res Telegramm das an das ISM8i 
#zurückgeschickt wird.
###############################################################
sub _ISM8I_create_answer($@)
{
   my ($name, $data) = @_;
 
   return "" if (length($data) <=0);
   
   my @datafields = @{ splitTelegrams($data) };
   my ($telegram, @h, @a, $answer, @answers);
   
   while (scalar(@datafields) > 0) {
      $telegram = shift(@datafields);
      if (length($telegram) >= 14) {
         @h = unpack("H2" x length($telegram), $telegram);
         if ($h[10] eq "f0" and $h[11] eq "06") {
            @a = ($h[0],$h[1],$h[2],$h[3],"00","11",$h[6],$h[7],$h[8],$h[9],$h[10],"86",$h[12],$h[13],"00","00","00");
		   	$answer = pack("H2" x 17, @a);
			push(@answers, $answer);
   
            Log3 $name, 5, "$name: created answer -->  "._ISM8I_dataToHex($answer);
         }
      }
   }
   
   return \@answers;
}


###############################################################
#                  _ISM8I_decodeThreadTelegram
###############################################################
#Telegramme entschlüsseln und die entsprechenden Werte zur 
#weiteren Entschlüsselung weiterreichen an sub _ISM8I_getCsvResult
###############################################################
sub _ISM8I_decodeThreadTelegram($@)
{
   #my ($name, $telegram) = @_;
   my ($name, $data) = @_;

   return if (length($data) <=0);

   my @datafields = @{ splitTelegrams($data) };
   my ($telegram, @h, $FrameSize, $MainService, $SubService, $StartDatapoint, $NumberOfDatapoints, $Position, $ignores, @ignore_dp, %ign_params);
   my ($n, $DP_ID, $DP_command, $DP_length, $v, $reading, $wert, $i, $DP_value, $auswertung, $last_auswertung, @fields, $ts, $rc); 

   while (scalar(@datafields) > 0) {
      $telegram = shift(@datafields);
      my @h = unpack("H2" x length($telegram), $telegram);
      my $hex_result = join(" ", @h);

      Log3 $name, 5, "$name: decode telegram ->   $hex_result";
 
      $FrameSize = hex($h[4].$h[5]);
      $MainService = hex($h[10]);
      $SubService = hex($h[11]);
   
      if ($FrameSize != length($telegram)) {
         Log3 $name, 4, "$name: decodeTelegram ERROR: TelegrammLength/FrameSize missmatch. [".$FrameSize."/".length($telegram)."]";
      } elsif ($SubService != 0x06) {
         Log3 $name, 4, "$name: decodeTelegram WARNING: No SetDatapointValue.Req. [".sprintf("%x", $SubService)."]";
      } elsif ($MainService == 0xF0 and $SubService == 0x06) {
         $StartDatapoint = hex($h[12].$h[13]);
         $NumberOfDatapoints = hex($h[14].$h[15]);
	     $Position = 0;
	     $ignores = AttrVal($name, "ignoreDatapoints", "1000 1001 1002");
         @ignore_dp = split(/ /, $ignores);
         %ign_params = map { $_ => 1 } @ignore_dp;

	     for ($n=1; $n <= $NumberOfDatapoints; $n++) {
            $DP_ID = hex($h[$Position + 16].$h[$Position + 17]);
            $DP_command = hex($h[$Position + 18]);
            $DP_length = hex($h[$Position + 19]);
            $v = "";
            $reading = "";
            $last_auswertung = "";
		 
            for ($i=0; $i <= $DP_length - 1; $i++) { $v .= $h[$Position + 20 + $i]; }
            $DP_value = hex($v);
	        $auswertung = time.";"._ISM8I_getCsvResult($DP_ID, $DP_value);

		    if ($auswertung ne $last_auswertung) {
		   	   $last_auswertung = $auswertung;
			 
			   @fields = split(/;/, $auswertung); # DP_ID [1]; Gerät [2]; Erignis [3]; Out/In [4]; Wert [5]; Einheit [6] (falls vorhanden)
     
			   if (!exists($ign_params{$fields[1]})) {  # <- ignoreDatapoints beachten
			      # Auswertung für FHEM erstellen 
	              $reading = _ISM8I_getFhemFriendly($fields[2]).".".$fields[1].".".$fields[4]."."._ISM8I_getFhemFriendly($fields[3]); # Geraet . DP ID . Out/In . Datenpunkt
			      if (scalar(@fields) == 7) { $reading .= "."._ISM8I_getFhemFriendly($fields[6]); } # Einheit (wenn vorhanden)
			      $wert = $fields[5]; # Wert (nach Leerstelle!)
			
			      # !!! Hier wird das decodierte Telegramm mit Wert hinzugefügt:
                  _ISM8I_enqueReadings($reading, $wert);
			      Log3 $name, 5, "$name: telegram result ->    $reading = $wert";
               } else {
			      Log3 $name, 5, "$name: telegram id $fields[1] ignored -> $reading = $wert";
               }
		    }
		    $Position += 4 + $DP_length;
	     }
      }
   }
}


###############################################################
#                  _ISM8I_enqueReadings
###############################################################
#Fügt Reading und Wert einer Queue zu die dann Timer-gesteuert 
#ausgegeben wird. Dient dazu um die Daten aus den Server Thread
#in den FHEM Thread zu bekommen.
###############################################################
sub _ISM8I_enqueReadings($$)
{
  my ($reading, $value) = @_;
  return if (!defined($reading) and !defined($value));

  if (!defined($reading)) { $reading = "_UNDEFINED"; }
  if (!defined($value)) { $value = "UNDEFINED"; }

  $dataQueue->enqueue(join($qSplitter, $reading, $value));
}


###############################################################
#                  _ISM8I_sendToThread
###############################################################
#Sendet Daten an den Server-Thread. 
#Möglichkeiten:
#   command = 'sendDatagramm' -> value = ferig vorbereitetes Datagramm zum Senden an das ISM8i Modul
#   command = 'showDebug' -> value = 'Inhalt der Attributs showDebug'
#   command = 'forewardAddress' -> value = 'Inhalt der Attributs forewardAddress'
###############################################################
sub _ISM8I_sendToThread($$)
{
  my ($command, $value) = @_;
  $_ISM8I_sendToThreadQueue->enqueue(join($qSplitter, $command, $value));
}


###############################################################
#                  _ISM8I_countWolfReadings
###############################################################
#Zählt alle ISM8i Readings. Debug und Status werden nicht 
#berücksichtigt.
###############################################################
sub _ISM8I_countWolfReadings($)
{
  my $hash = shift;
  my $c = 0;
  my $r;
	
  if ( +(keys %{$hash->{READINGS}}) > 0 ) {
     foreach $r ( keys %{$hash->{READINGS}} ) {
       if ( ($r !~ m/^_/) and ($r ne "state") ) { $c ++ } 
     }
  }
	
  return $c;
}


###############################################################
#                  _ISM8I_deleteIgnores
###############################################################
sub _ISM8I_deleteIgnores($)
{
   my $hash = shift;
   my $name = $hash->{NAME};
   my $ignores = AttrVal($name, "ignoreDatapoints", "");
   my @datapoints = split(/ /, $ignores);

   foreach my $dp (@datapoints) { 
      my $reading = _ISM8I_find_reading_on_dp($hash, $dp);
      if ( defined($reading) ) { fhem("deletereading $name $reading");; }
   }
}


###############################################################
#                  _ISM8I_loadDatenpunkte
###############################################################
#Datenpunkte aus einem CSV File (Semikolon-separiert) laden.
#Die Reihenfolge der CSV Spalten lautet: ID; Gerät; Datenpunkt; 
#KNX-Datenpunkttyp; Output/Input; Einheit
#Die einzelnen CSV Felder dürfen keine Kommas, Leerstellen oder 
#Anführungszeichen enthalten.
###############################################################
sub _ISM8I_loadDatenpunkte
{
   #erstmal vorsichtshalber datenpunkte array löschen:
   while(@datenpunkte) { shift(@datenpunkte); }
   
   my $file = "./FHEM/wolf_datenpunkte_15.csv";
   my $data;
   my $c = 0;
   open($data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";
   
   while (my $line = <$data>) {
     my @fields = split(/;/, _ISM8I_r_trim($line));
	 if (scalar(@fields) == 6) {
	    $datenpunkte[0 + $fields[0]] = [ @fields ]; # <-so hinzufügen, damit der Index mit der DP ID übereinstimmt zu einfacheren Suche.
		$c ++;
	 }
   }
  
  close $data;
  Log3 undef, 4, "WOLF_ISM8I: _ISM8I_loadDatenpunkte -> $c";

}


###############################################################
#                  _ISM8I_loadSetter
###############################################################
#Datenpunkte aus einem CSV File (Semikolon-separiert) laden.
#Die Reihenfolge der CSV Spalten lautet: 
#0 = DP ID, 1 = Gerät, 2 = Datenpunkt, 3 = Einheit,
#4 = Wertebereich, 5 = Schrittweite 
#Die einzelnen CSV Felder dürfen keine #, Kommas, Leerstellen 
#oder Anführungszeichen enthalten.
###############################################################
sub _ISM8I_loadSetter
{
   #erstmal vorsichtshalber writepunkte array löschen:
   while(@writepunkte) { shift(@writepunkte); }
   
   my $file = "./FHEM/wolf_writepunkte_15.csv";
   my ($data, $line, @fields, $setter, $dpid, $geraet, $datenpunkt, $einheit, $widget);
   my $c = 0;

   open($data, '<:encoding(UTF-8)', $file) or die "Could not open '$file' $!\n";
   
   while ($line = <$data>) {
	 if ($line !~ /#/) {
        @fields = split(/;/, _ISM8I_r_trim($line));
	    if (scalar(@fields) == 6) {
		   $c ++;
	       $writepunkte[0 + $fields[0]] = [ @fields ]; # <-so hinzufügen, damit der Index mit der DP ID übereinstimmt zu einfacheren Suche.
	       $dpid = $fields[0];
	       $geraet = _ISM8I_getFhemFriendly($fields[1]);
	       $datenpunkt = _ISM8I_getFhemFriendly($fields[2]);
	       $einheit = _ISM8I_getFhemFriendly($fields[3]);
           $setter = "$geraet.$dpid.$datenpunkt";
		   if (length($einheit) > 0) { $setter .= ".$einheit"; }
		   $widget = _ISM8I_getSetterWidget($fields[4], $fields[5]);
		   if (length($widget) > 0) { $setter .= ":$widget"; }

	       $sets{$setter}="noArg"; # %sets ist die global definierte Setter Variable
		   
	       #Log3 undef, 3, "WOLF_ISM8I: _ISM8I_loadSetter -> $setter"; 
		}
	 }
   }
	
   close $data;
   Log3 undef, 4, "WOLF_ISM8I: _ISM8I_loadSetter -> $c";
}


###############################################################
#                  _ISM8I_getSetterWidget
###############################################################
sub _ISM8I_getSetterWidget($$)
{
	my $b = shift;
	my $s = shift;
	
	if ($b eq "0-1" && $s eq "1") {
		return "uzsuSelectRadio,0,1";
	} 
	elsif ($b eq "20-80" && $s eq "1") {
		return "selectnumbers,20,1,80,0,lin";
	} 
	elsif ($b eq "0-3" && $s eq "1") {
		return "uzsuSelectRadio,0,1,2,3";
	} 
	elsif ($b eq "0/2/4" && $s eq "-") {
		return "uzsuSelectRadio,0,2,4";
	} 
	elsif ($b eq "0/1/3" && $s eq "-") {
		return "uzsuSelectRadio,0,1,3";
	} 
	elsif ($b eq "m4-4" && $s eq "0.5") {
		return "selectnumbers,-4,0.5,4,1,lin";
	} 
	elsif ($b eq "0-10" && $s eq "0.5") {
		return "selectnumbers,0,0.5,10,1,lin";
	} 
	elsif ($b eq "-" && $s eq "Tag") {
		return "select,-,Montag,Dienstag,Mittwoch,Donnerstag,Freitag,Samstag,Sonntag";
	} 
	elsif ($b eq "-" && $s eq "Minute") {
		return "time";
	} 
	elsif ($b eq "0-100" && $s eq "1") {
		return "selectnumbers,0,1,100,0,lin";
	} else {
		return "";
	}
}	


###############################################################
#                  _ISM8I_dataToHex
###############################################################
#Wandelt Daten in HEX Werte zur besseren Darstellung von 
#unleserlichen Werten.
###############################################################
sub _ISM8I_dataToHex($)
{
   my $data = shift;
   return "" if (length($data) <= 0);
   my @h = unpack("H2" x length($data), $data);
   return join(" ", @h);
}


###############################################################
# this sub converts a decimal IP to a dotted IP
sub _ISM8I_dec2ip($) { join '.', unpack 'C4', pack 'N', shift; }

###############################################################
# this sub converts a dotted IP to a decimal IP
sub _ISM8I_ip2dec($) { unpack N => pack CCCC => split /\./ => shift; }

###############################################################
### Whitespace (v.a. CR LF) rechts im String löschen

sub _ISM8I_r_trim { my $s = shift; $s =~ s/\s+$//; return $s; }

###############################################################
### Whitespace links im String löschen

sub _ISM8I_l_trim { my $s = shift; $s =~ s/^\s+//; return $s; }

###############################################################
### Allen Whitespace im String löschen

sub _ISM8I_al_l_trim { my $s = shift; $s =~ s/\s+//g; return $s; }

###############################################################
### Doppelten Whitespace im String durch ein Leezeichen ersetzen

sub _ISM8I_db_l_trim { my $s = shift; $s =~ s/\s+/ /g; return $s; }

###############################################################
### _ISM8I_r_trim, _ISM8I_l_trim, _ISM8I_db_l_trim zusammen auf einen String anwenden

sub _ISM8I_l_r_db_l_trim { my $s = shift; my $r = _ISM8I_l_trim(_ISM8I_r_trim(_ISM8I_db_l_trim($s))); return $r; }


###############################################################
#                  _ISM8I_find_reading_on_dp
###############################################################
### Schreibt alle vorhandenen Readings ins Log
###############################################################
sub _ISM8I_find_reading_on_dp($$) 
{
  my ($hash, $find) = @_;
  if ($find !~ m/^\d{1,3}$/) { return undef; }
  
  my $regx = "^.*\\.$find\\..*"; # /^.*\.\d{1,3}\..*/
  my $r;
  
  foreach $r ( keys %{ $hash->{READINGS} } ) { 
    if ($r =~ m/$regx/) { return $r; }
  }
  
  return undef;  
}


###############################################################
#                  _ISM8I_getFhemFriendly
###############################################################
#Ersetzt alle Zeichen so, dass das Ergebnis als FHEM Reading 
#Name taugt.
###############################################################
sub _ISM8I_getFhemFriendly($)
{
   my $working_string = shift;
   my @tbr = ("-","","ö","oe","ä","ae","ü","ue","Ö","Oe","Ä","Ae","Ü","Ue","ß","ss","³","3","²","2","°C","C","%","proz","[[:punct:][:space:][:cntrl:]]","_","___","_","__","_","^_","","_\$","");
   my ($i, $f, $r);
   
   if (defined($working_string)) {
      for ($i=0; $i <= scalar(@tbr)-1; $i+=2) {
         $f = $tbr[$i];
         if ($working_string =~ /$f/) {
            $r = $tbr[$i+1];
	        $working_string =~ s/$f/$r/g;
	     }
      }
      return $working_string;
   } else {
	  return "";
   }
}


###############################################################
#                  _ISM8I_getFhemInOut
###############################################################
#Verwandelt die Out/In Angabe (ob ein Datenpunkt auch Eingaben 
#akzeptiert) in das FHEM freundlichen IO, I oder O.
###############################################################
sub _ISM8I_getFhemInOut($)
{
  my $working_string = shift;
  my $result = "";

  if ($working_string =~ /In/) { $result .= "I"; }
  if ($working_string =~ /Out/) { $result .= "O"; }

return $result;
}


###############################################################
#                  _ISM8I_getDatenpunkt
###############################################################
#Returnt aus dem 2D Array mit Datenpunkten den Datenpunkt als 
#Array mit der übergebenen DP ID.
#$0 = DP ID / $1 = Index des Feldes -> (0 = DP ID, 1 = Gerät, 
#2 = Datenpunkt, 3 = KNX-Datenpunkttyp, 4 = Output/Input, 
#5 = Einheit)
###############################################################
sub _ISM8I_getDatenpunkt($$)
{
   my ($dpid, $index) = @_;
   my $d = $datenpunkte[$dpid][$index];
   if ( (defined $d) and (length($d)>0) ) { return $d; } else { return "ERROR:NotFound"; } 
}


###############################################################
#                  _ISM8I_getCsvResult
###############################################################
#Berchnet den Inhalt des Telegrams und gibt das Ergebnis im 
#CSV Mode ';'-separiert.
#$0 = DP ID / $1 = DP Value
#Ergebnis: DP_ID [1]; Gerät [2]; Datenpunkt [3]; Out/In [4]; 
#Wert [5]; Einheit [6] (falls vorhanden)
###############################################################
sub _ISM8I_getCsvResult($$)
{
   my ($dp_id, $dp_val) = @_;
   my $geraet = _ISM8I_getDatenpunkt($dp_id, 1);
   my $datenpunkt = _ISM8I_getDatenpunkt($dp_id, 2);
   my $datatype = _ISM8I_getDatenpunkt($dp_id, 3);
   my $inout = _ISM8I_getFhemInOut(_ISM8I_getDatenpunkt($dp_id, 4));
   my $result = $dp_id.";".$geraet.";".$datenpunkt.";".$inout.";";
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
	  $result .= _ISM8I_convert_DptScalingToNumber($dp_val).";%"; 
	 }
   elsif ($datatype eq "DPT_Value_Temp") 
     {
	  $result .= sprintf("%.1f", _ISM8I_convert_DptFloatToNumber($dp_val)).";°C";
	 }
   elsif ($datatype eq "DPT_Value_Tempd") 
     {
	  $result .= sprintf("%.1f", _ISM8I_convert_DptFloatToNumber($dp_val)).";K";
	 }
   elsif ($datatype eq "DPT_Value_Pres") 
     {
	  $result .= _ISM8I_convert_DptFloatToNumber($dp_val).";Pa";
	 }
   elsif ($datatype eq "DPT_Power") 
     {
	  $result .= _ISM8I_convert_DptFloatToNumber($dp_val).";kW";
	 }
   elsif ($datatype eq "DPT_Value_Volume_Flow") 
     {
	  $result .= _ISM8I_convert_DptFloatToNumber($dp_val).";l/h";
	 }
   elsif ($datatype eq "DPT_TimeOfDay") 
     {
	  $result .= _ISM8I_convert_DptTimeToString($dp_val);
	 }
   elsif ($datatype eq "DPT_Date") 
     {
	  $result .= _ISM8I_convert_DptDateToString($dp_val);
	 }
   elsif ($datatype eq "DPT_FlowRate_m3/h") 
     {
	  $result .= (_ISM8I_convert_DptLongToNumber($dp_val) * 0.0001).";m³/h";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy") 
     {
	  $result .= _ISM8I_convert_DptLongToNumber($dp_val).";Wh";
	 }
   elsif ($datatype eq "DPT_ActiveEnergy_kWh") 
     {
	  $result .= _ISM8I_convert_DptLongToNumber($dp_val).";kWh";
	 }
   elsif ($datatype eq "DPT_HVACMode") 
     {
	  my @Heizkreis = ("Automatikbetrieb","Heizbetrieb","Standby","Sparbetrieb","-");

	  my @CWL = ("Automatikbetrieb","Nennlüftung","-","Reduzierung Lüftung","-");
	 
      if ($geraet =~ /Heizkreis/ or $geraet =~ /Mischerkreis/)
	   	{ $v = $Heizkreis[$dp_val]; }
	  elsif ($geraet =~ /CWL/)
	   	{ $v = $CWL[$dp_val]; }
      
	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_DHWMode") 
     {
	  my @Warmwasser = ("Automatikbetrieb","-","Dauerbetrieb","-","Standby");

      if ($geraet =~ /Warmwasser/) { $v = $Warmwasser[$dp_val]; }

	  if (defined $v) { $result .= $v; } else { $result .= "ERR:NoResult[".$dp_id."/".$dp_val."]";}
	 }
   elsif ($datatype eq "DPT_HVACContrMode") 
     {
	  my @CGB2_MGK2_TOB = ("Schornsteinferger","Heiz- Warmwasserbetrieb","-","-","-","-","Standby","Test","-","-","-","Frostschutz","-","-","-","Kalibration");

      my @BWL1S = ("Antilegionellenfunktion","Heiz- Warmwasserbetrieb","Vorwärmung","Aktive Kühlung","-","-","Standby","Test","-","-","-","Frostschutz","-","-","-","-");
				   
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


###############################################################
#                  _ISM8I_codeSetting
###############################################################
#Erzeugt ein Datagramm dass an ISM8i gesendet wird nach einem 'set'
###############################################################
sub _ISM8I_codeSetting($$)
{
   my ($id, $value) = @_;
   my $type = _ISM8I_getDatenpunkt($id, 3);
   my $dpv = _ISM8I_codeValueByType($type, $value); # DP Value
   
   if (defined($dpv)) {
      my $dp = _ISM8I_convert_NumberToChars($id, 2); # DP Id
      my $dpvLength = _ISM8I_convert_NumberToChars(length($dpv), 1);
      my $ipHeader = chr(0x06).chr(0x20).chr(0xf0).chr(0x80);
      my $conHeader = chr(0x04).chr(0x00).chr(0x00).chr(0x00);
      my $objMsg = chr(0xf0).chr(0xc1).$dp.chr(0x00).chr(0x01).$dp.chr(0x00).$dpvLength.$dpv;
      my $frameSize = _ISM8I_convert_NumberToChars(2 + length($ipHeader) + length($conHeader) + length($objMsg), 2);
	  
      #Debug("ISM8i _ISM8I_codeSetting: id->$id / value->$value / type->$type / dpv->"._ISM8I_dataToHex($dpv)." / dpvLength->"._ISM8I_dataToHex($dpvLength));
   
	  $ipHeader = $ipHeader.$frameSize;
      return $ipHeader.$conHeader.$objMsg;
   } else {
	  return "";
   }
}


###############################################################
#                  _ISM8I_codeValueByType
###############################################################
#Erzeugt ein Datagramm-Wert zum Senden an das ISM8i nach einem 'set'
###############################################################
sub _ISM8I_codeValueByType($$)
{
   my ($type, $val) = @_;
   my $ret = undef;
   
   if ($type eq "DPT_Switch") {
	  if ($val == 0 or $val == 1) { $ret = _ISM8I_convert_NumberToChars($val & 0xff, 1); }
   }
   elsif ($type eq "DPT_Value_Temp" or $type eq "DPT_Value_Tempd") {
      $ret = _ISM8I_convert_NumberToChars(_ISM8I_convert_NumberToDptFloat($val), 2);
   }
   elsif ($type eq "DPT_HVACMode" or $type eq "DPT_DHWMode") {
	  if ($val >= 0 and $val <= 4) { $ret = _ISM8I_convert_NumberToChars($val & 0xff, 1); }
   }
   elsif ($type eq "DPT_Date") {
      $ret = _ISM8I_convert_NumberToChars(_ISM8I_convert_StringToDptTime_DayOnly($val), 3);
   }
   elsif ($type eq "DPT_TimeOfDay") {
      $ret = _ISM8I_convert_NumberToChars(_ISM8I_convert_StringToDptTime_TimeOnly($val), 3);
   }
   elsif ($type eq "DPT_Scaling") {
      $ret = _ISM8I_convert_NumberToChars(_ISM8I_convert_NumberToDptScaling($val), 1);
   }
   
   return $ret;
}	


###############################################################
#                  _ISM8I_convert_NumberToChars
###############################################################
#Hilsfunktion für '_ISM8I_codeValueByType'. Maximal 4 Byte lang! 
###############################################################
sub _ISM8I_convert_NumberToChars($$)
{
   my ($val,$len) = @_;
   my $res;
   
   if ($len == 1) {
	  $res = pack("C", _ISM8I_getByteweise($val, 0));
   } elsif ($len == 2) {
	  $res = pack("C*", _ISM8I_getByteweise($val, 1), _ISM8I_getByteweise($val, 0));
   } elsif ($len == 3) {
	  $res = pack("C*", _ISM8I_getByteweise($val, 2), _ISM8I_getByteweise($val, 1), _ISM8I_getByteweise($val, 0));
   } elsif ($len == 4) {
	  $res = pack("C*", _ISM8I_getByteweise($val, 3), _ISM8I_getByteweise($val, 2), _ISM8I_getByteweise($val, 1), _ISM8I_getByteweise($val, 0));
   }
   
   return $res;
}

###############################################################
#                  _ISM8I_getLen
###############################################################
# Bestimmt die Bytelänge einer Zahl an Hand ihres Wertes.
###############################################################
sub _ISM8I_getLen($)
{
   my $val = shift;
   my $len = 0;
  
   if ($val < 2**8) {
      $len = 1; 
   } elsif ($val >= 2**8 and $val < 2**16) {
      $len = 2; 
   } elsif ($val >= 2**16 and $val < 2**24) {
      $len = 3; 
   } elsif ($val >= 2**24) {
      $len = 4; 
   } 
   
   return $len;
}	
   

###############################################################
# 2-Octet Float Value
###############################################################
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
###############################################################

###############################################################
#                  _ISM8I_convert_DptFloatToNumber
###############################################################
sub _ISM8I_convert_DptFloatToNumber($)
{
   #use bignum;
  
   my $val = shift;
   
   if ($val == 0x7fff) { return "invalid"; }
   
   my $sign = ($val & 0x8000) >> 15;
   my $mantisse = $val & 0x07ff;
   my $exponent = ($val & 0x7800) >> 11;

   if ($sign != 0) { $mantisse = -(~($mantisse - 1) & 0x07ff); } 
   #if ($val & 0x8000) { $mantisse = ~$mantisse; } # negative number in two complement
   
   #return ($mantisse * 0.01) * (2 ** $exponent);
   return (1 << $exponent) * 0.01 * $mantisse;
}

###############################################################
#                  _ISM8I_convert_NumberToDptFloat
###############################################################
sub _ISM8I_convert_NumberToDptFloat($)
{
   my $val = shift;
   
   return 0x7fff if ($val <= -671088.64 or $val >= 670760.96);
   
   $val = ($val * 100);
   my $sign = 0;
   my $exponent = 0;
   my $mantisse = 0;

   if ($val < 0) {
      $sign = 1;
      $mantisse = ~$val;
   } else {
      $mantisse = $val;
   }

   while ($mantisse > 2047) {
     $mantisse = $mantisse / 2;
     $exponent ++;
   }

   return ($sign << 15) | ($exponent << 11) | $mantisse;
}


###############################################################
#                  _ISM8I_convert_DptLongToNumber
###############################################################
# Format: 4 octets: V32
# octet nr: 4MSB 3 2 1LSB
# field names: SignedValue
# encoding: VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV
# Encoding: Two‘s complement notation
# Range: SignedValue = [-2 147 483 648 ... 2 147 483 647]
# PDT: PDT_LONG 
###############################################################
sub _ISM8I_convert_DptLongToNumber($)
{
   my $val = shift;
   return $val;
}


###############################################################
# DPT_Scaling
###############################################################
# Format: 8 bit: U8
# octet nr: 1
# field names: Unsigned Value
# encoding: UUUUUUUU
# Encoding: binary encoded
#           msb         lsb
#           U U U U U U U U
#           0 0 0 0 0 0 0 0 = range min./off
#           0 0 0 0 0 0 0 1 = value „low“
#           :     :       :
#           1 1 1 1 1 1 1 1 = range max.
# Range: U = [0...255]
#
# ID:   Name:       Range:    Unit: Resol.:   PDT: 
# 5.001 DPT_Scaling [0...100] %     ≈ 0,4 %   PDT_SCALING
#                                   (100/255) (alt.: PDT_UNSIGNED_CHAR)
###############################################################

###############################################################
#                  _ISM8I_convert_DptScalingToNumber
###############################################################
sub _ISM8I_convert_DptScalingToNumber($)
{
   my $val = shift;
   my $result = ($val & 0xff) * 100 / 255; 
   return sprintf("%.0f", $result);
}

###############################################################
#                  _ISM8I_convert_NumberToDptScaling
###############################################################
sub _ISM8I_convert_NumberToDptScaling($)
{
   my $val = shift;
   if ($val <= 0 or $val >= 100) { return 0x7fff; } 
   my $result = $val * 255 / 100; 
   return sprintf("%.0f", $result);
}


###############################################################
# DPT_TimeOfDay
###############################################################
# 3 Byte Time
#
# 22221111 111111 
# 32109876 54321098 76543210
# DDDHHHHH RRMMMMMM RRSSSSSS
# R Reserved
# D Weekday
# H Hour
# M Minutes
# S Seconds
# PDT: PDT_TIME
###############################################################

###############################################################
#                  _ISM8I_convert_DptTimeToString
###############################################################
sub _ISM8I_convert_DptTimeToString($)
{
   my $val = shift;
   
   my @weekdays = ["-","Mo","Di","Mi","Do","Fr","Sa","So"];
   my $weekday = _ISM8I_getBitweise($val, 21, 23);
   my $hour = _ISM8I_getBitweise($val, 16, 20);
   my $min = _ISM8I_getBitweise($val, 8, 13);
   my $sec = _ISM8I_getBitweise($val, 0, 5);

   return sprintf("%s %d:%d:%d", $weekdays[$weekday], $hour, $min, $sec);
}


###############################################################
#                  _ISM8I_convert_StringToDptTime_DayOnly
###############################################################
#Übersetzt nur den Wochentag. Die Uhrzeit ist 0.
###############################################################
sub _ISM8I_convert_StringToDptTime_DayOnly($)
{
   my $val = shift;
   my $day = substr(uc(_ISM8I_al_l_trim($val)),0,2); # Ersten 2 Buchstaben des von Whitespace gereinigten und nach uppercase konvertierten Wert. 
   my @weekdays = ("-","MO","DI","MI","DO","FR","SA","SO"); # ^MO|^DI|^MI|^DO|^FR|^SA|^SO
   my $d;
   my $i = -1;
   my $c = 0;
   
   foreach $d (@weekdays) { 
      if ($d eq $day) { $i = $c; } # Index im Array
	  $c ++;
   }

   #Debug("ISM8i _ISM8I_convert_StringToDptTime_DayOnly: val->$val / day->$day / i->$i");

   return 0x7fff if ($i == -1); # Invalide value
   
   return ($i & 0b00000111) << 21;   
}


###############################################################
#                  _ISM8I_convert_StringToDptTime_TimeOnly
###############################################################
#Übersetzt nur die Uhrzeit. Der Wochentag ist 0.
###############################################################
sub _ISM8I_convert_StringToDptTime_TimeOnly($)
{
   my $val = shift;
   my @date = split(/:/, $val);
   if (scalar(@date) < 2) { @date = split(/:/, "12:00:00"); }
   if (scalar(@date) == 2) { @date = split(/:/, $val.":00"); }
   my $hh = $date[0] & 0b00011111;
   my $mm = $date[1] & 0b00111111;
   my $ss = $date[2] & 0b00111111;

   return 0x7fff if ($hh < 0 or $hh > 23 or $mm < 0 or $mm > 59 or $ss < 0 or $ss > 59); # Invalide value
   
   my $ret = $ss + ($mm << 8) + ($hh << 16);
   
   return $ret;
}


###############################################################
# DPT_Date
###############################################################
# 3 byte Date
#
# 22221111 111111 
# 32109876 54321098 76543210
# RRRDDDDD RRRRMMMM RYYYYYYY
# R Reserved
# D Day
# M Month
# Y Year
###############################################################

###############################################################
#                  _ISM8I_convert_DptDateToString
###############################################################
sub _ISM8I_convert_DptDateToString($)
{
   my $val = shift;
   my $day = _ISM8I_getBitweise($val, 16, 20);
   my $mon = _ISM8I_getBitweise($val, 8, 11);
   my $year = _ISM8I_getBitweise($val, 0, 6);
   if ($year < 90) { $year += 2000; } else { $year += 1900; }
   return sprintf("%02d.%02d.%04d", $day, $mon, $year);
}


###############################################################
#                  _ISM8I_convert_StringToDptDate
###############################################################
sub _ISM8I_convert_StringToDptDate($)
{
   my $val = shift;
   $val = _ISM8I_al_l_trim($val);
   return 0x7fff if($val !~ m/^\d{1,2}\.\d{1,2}\.\d{4}/);
   
   my @date = split(/./, $val);
   my $day= $date[0] & 0b00011111;
   return 0x7fff if($day < 1 or $day > 31);
   my $mon = $date[1] & 0b00001111;
   return 0x7fff if($mon < 1 or $mon > 12);
   my $year = $date[2] & 0b01111111;
   return 0x7fff if($year < 2000 or $year > 2099);
   $year -= 2000;
   my $ret = $year + ($mon << 8) + ($day << 16);
   
   return $ret;
}

###############################################################
#                  _ISM8I_getBitweise
###############################################################
#Berechnet aus einer Zahl eine Zahl anhand der vorgegebenen Bits.
#Maximal 4 Byte
#$1 = Zahl, $2 = Startbit (0-basiert), $3 = Endbit
###############################################################
sub _ISM8I_getBitweise($$$)
{
   my ($val, $start_bit, $end_bit) = @_;
   my ($b, $result);
   my $mask = 0;
   
   for $b ($start_bit..$end_bit) {
      $mask = $mask | (2 ** $b);
   }
   $result = ($val & $mask) >> $start_bit;
   return $result;
}


###############################################################
#                  _ISM8I_setBitwise
###############################################################
#Setzt Bits an eine entsprechende Stelle einer Zahl falls der Bits
#in der Ausgangszahl (Bit 0-basiert) vorhanden ist.
#$1 = Ausgangszahl, 
#$2 = Startbit in der neuen Zahl, 
#$3 = Endbit  in der neuen Zahl
###############################################################
sub _ISM8I_setBitwise($$$)
{
   my ($val, $start_bit, $end_bit) = @_;
   my $newval = 0;
   my $i = 0;
   
   for ($i , $i <= ($end_bit - $start_bit), $i++) {
      if ($val & 2 ** $i) { $newval = $newval + (2 ** ($i + $start_bit)); }
   }
   
   return $newval;
}


###############################################################
#                  _ISM8I_getByteweise
###############################################################
#Extrahiert aus einer Zahl den Byte an den geforderten Stelle.
#$0 = Zahl, $1 = Bytenummer (0-basiert, rechts anfangend)
###############################################################
sub _ISM8I_getByteweise($$)
{
   my ($val, $byte) = @_;
   my $mask = 0xff << ($byte * 8);
   my $res = ($val & $mask) >> ($byte * 8);
   
   return $res;
}


1;

=pod
=item device
=item summary    
=item summary_DE misst und steuert Wolf Geräte.
=begin html

=end html
=begin html_DE

=end html_DE

=cut
