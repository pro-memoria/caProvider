package CollectiveAccess::Scelsi::SQL;

use strict;
use warnings;

use DBI;
use Data::Dumper;
use Promemoria::SAN::EAD;

use constant {
    PERM_ELEMENT_ID => 479,
    CA_OBJECTS_TABLE_NUM => 57,
    CA_ENTITIES_TABLE_NUM => 20,
};

my %METADATA_TABLE_NUM = (
			  'ead-san'=>CA_OBJECTS_TABLE_NUM,
			  'eac-san'=>CA_ENTITIES_TABLE_NUM,
			  'scons-san'=>CA_ENTITIES_TABLE_NUM,
);


=head2

=cut

##TODO Compilare in modo corretto gli array
#my @CONSERVATORI = ({permaid=>'fdsfdg34353532',formaautorizzata=>''....});
#my @PRODUTTORI = ({permaid=>'fdsfdg34353532',formaautorizzata=>''....},{});

sub Metadata_table_num {
    my($metadataPrefix)=@_;
    return $METADATA_TABLE_NUM{$metadataPrefix};
}

sub ListIdentifiers {
    my ($dbh, $until, $from) = @_;
    my $sth;
    if (($until && $from) && ($until > $from)) {
	my $sql = q(select cv.value_longtext1,
		    date(from_unixtime(coalesce(l.date,1438066748))) as date 
		    from ca_attribute_values as cv, ca_attributes as ca 
		    left join (select logged_row_id as row_id,max(log_datetime) as date from ca_change_log where logged_table_num=? group by logged_row_id) as l 
		    on (l.row_id=ca.row_id) 
		    where ca.table_num=? and ca.element_id=cv.element_id and ca.attribute_id=cv.attribute_id and cv.element_id=?
		    and l.date between unix_timestamp(?) and unix_timestamp(?)
		   );
	
	$sth = $dbh->prepare($sql);
	$sth->execute(CA_OBJECTS_TABLE_NUM,CA_OBJECTS_TABLE_NUM,PERM_ELEMENT_ID,$from,$until);
    } else {
	my $sql = q(select cv.value_longtext1,
		    date(from_unixtime(coalesce(l.date,1438066748))) as date 
		    from ca_attribute_values as cv, ca_attributes as ca 
		    left join (select logged_row_id as row_id,max(log_datetime) as date from ca_change_log where logged_table_num=? group by logged_row_id) as l 
		    on (l.row_id=ca.row_id) 
		    where ca.table_num=? and ca.element_id=cv.element_id and ca.attribute_id=cv.attribute_id and cv.element_id=?
		   );
	#        and l.date between to_seconds(?) and to_seconds(?) 
	
	$sth = $dbh->prepare($sql);
	$sth->execute(CA_OBJECTS_TABLE_NUM,CA_OBJECTS_TABLE_NUM,PERM_ELEMENT_ID);
    }
    my $data = $sth->fetchall_arrayref;
    $sth->finish;
    return $data;
}


sub ListMetadataFormats {
    my ($dbh, $identifier) = @_;
    my $sql = q(select ca.table_num
		from ca_attribute_values as cv, ca_attributes as ca 
		where ca.element_id=cv.element_id and ca.attribute_id=cv.attribute_id and cv.element_id=?
		and cv.value_longtext1 = ?
	);
    
    my $sth = $dbh->prepare($sql);
    $sth->execute(PERM_ELEMENT_ID, $identifier);

    if ($sth->rows) {
	my $metadataPrefix;
	my ($table_num) = $sth->fetchrow_array;	
	$sth->finish;
	if (CA_OBJECTS_TABLE_NUM == $table_num) {
	    return 'ead-san';
	} elsif (CA_ENTITIES_TABLE_NUM == $table_num) {
	    ##TODO inserire gestione scons o eac - vedi array in testa
	    return 'eac-san';
	} ############ elsif (CA_ENTITIES_TABLE_NUM == $table_num) {
    } else {
	die('identifier not found');
    }
}


sub GetRecord_check_identifier {
    my ($dbh, $identifier) = @_;
    
	my $sql = q(select ca.table_num,row_id
		    from ca_attribute_values as cv, ca_attributes as ca 
		    where ca.element_id=cv.element_id and ca.attribute_id=cv.attribute_id and cv.element_id=?
		    and cv.value_longtext1 = ?
		   );
	
	my $sth = $dbh->prepare($sql);
	$sth->execute(PERM_ELEMENT_ID, $identifier);
	if ($sth->rows) {
	    my ($table_num,$object_id) = $sth->fetchrow_array;
	    $sth->finish;
	    return ($table_num, $object_id);
	}
    $sth->finish;
    return;
}

use constant {
    SCELSI_SCONS => 275,  # questo ci sarà solo sulla root
    SCELSI_PROD  => 237.  # questo e' ripetibile
};


=head2 CostruisciEAD

Prima estrae i dati dal db, dunque chiama Promemoria::SAN::EAD per assemblare la
struttura dati SAN::EAD.

=cut

sub CostruisciEAD {
    my ($dbh, $object_id) = @_;

    die("$dbh undef") unless ($dbh);

    my $obj;
    {
	# assumo che se il padre non e' visibile non lo sia manco il figlio
	# per cui non passo dal ca_objects del parent, e accedo direttamente ai suoi metadati.

	my $sql = q[
SELECT o.object_id, o.idno, o.type_id, l.name, l.is_preferred, li.item_value, av.value_longtext1 as parent_uuid
  FROM 
       ca_object_labels l,
       ca_list_items as li,
       ca_objects o
       -- aggiungo i dati per estrarre la relazione con il padre (eventuale)
       left join ca_attributes as a on (o.parent_id=a.row_id)
       left join ca_attribute_values as av on (a.attribute_id=av.attribute_id and av.element_id=?)  -- 479
 WHERE o.object_id = l.object_id and o.access = 1 and o.deleted=0 and o.type_id=li.item_id and o.object_id=?
	 and l.is_preferred=1
  -- se estraesse anche gli altri: order by l.is_preferred desc, l.name
];

	my $sth = $dbh->prepare($sql);
	$sth->execute(CA_OBJECTS_TABLE_NUM, $object_id);
	unless ($sth->rows) {
	    die("Not found $object_id");
	}

	$obj = $sth->fetchrow_hashref;
	if (!defined $obj || !exists $obj->{name}) {
	    die("oggetto non trovato $object_id\n$sql\n(CA_OBJECTS_TABLE_NUM, $object_id)\n");
	}
	# caso che per ora non si verifica:
	if ($sth->rows > 1) {
	    # posso avere tanti record quanti sono i nomi dell'oggetto
	    ## devo sistemare questo aspetto.
	    my @more_names = ();
	    while (my $o = $sth->fetchrow_hashref) {
		push(@more_names, $o->{name});
		# potrebbe associarlo a li.item_value
	    }
	    $obj->{more_names}=\@more_names;
	    $sth->finish;
	}
    }

    my $attrs = {};
    {
	# estraiamo tutti gli attributi che servono:

	my @attributi = qw/ genreform data_range scopecontent consistenza perm_id/;

	my $sql = q[
SELECT me.element_code, av.value_longtext1 
  FROM ca_objects o, 
       ca_attributes a,
       ca_attribute_values av, 
       ca_metadata_elements me 
 WHERE
       o.object_id = a.row_id and
       a.attribute_id = av.attribute_id and
       a.element_id = me.element_id and
       o.deleted = 0 and
       o.access = 1 and
       a.table_num = ? and
       o.object_id=? and
       -- tolgo gli attributi con valori nulli o vuoti
       av.value_longtext1 is not null AND 
       av.value_longtext1 <> '' and
       me.element_code in ( '] . join("','", @attributi) . q[' )];

	# @attributi e' una variabile locale, non puo' avvenire alcun SQL injection da qui e
	# quindi mi fido a metterlo inline nella query

	my $sth = $dbh->prepare($sql);
	die('$sth undef') unless($sth);
	$sth->execute(CA_OBJECTS_TABLE_NUM, $object_id);

	unless ($sth->rows > 0) {
	    die("no result:\n $sql \n (CA_OBJECTS_TABLE_NUM, $object_id) \n");
	}


	if (0) {
	    # forzo gli attributi ad essere un array... 
	    while (my $ar = $sth->fetchrow_arrayref) {
		if (exists $attrs->{$ar->[0]} ) {
		    push (@{$attrs->{$ar->[0]}}, $ar->[1]);
		} else {
		    $attrs->{$ar->[0]}=[$ar->[1]];
		}
	    }
	}
	# non ci sono multivalore
	while (my $ar = $sth->fetchrow_arrayref) {
	    $attrs->{$ar->[0]}=$ar->[1];
	}
	$sth->finish;
    }

    my $scons;
    my $prod = [];
    {
	#
	# prendiamo le entità correlate.
	#

	my $sql = q(
SELECT el.name as entity_name, av.value_longtext1 as entity_uuid, coe.type_id as relationship_type
  FROM ca_objects_x_entities as coe, ca_entity_labels as el, ca_attribute as a, ca_attribute_values as av
 WHERE 
       coe.object_id = ?  -- il punto di partenza della ricerca
       el.entity_id=coe.entity_id and
       a.table_num=? -- 20
       a.row_id=coe.entity_id and
       av.element_id=a.element_id and
       av.attribute_id=a.attribute_id and
       av.element_id=? and      -- 479 o CA_ENTITIES_TABLE_NUM
       and coe.type_id in (?,?) -- 275 e 237
       and el.is_preferred
ORDER BY coe.type_id desc
);


	my $sth = $dbh->prepare($sql);
	$sth->execute($object_id, CA_ENTITIES_TABLE_NUM, PERM_ELEMENT_ID, SCELSI_SCONS, SCELSI_PROD);
	# avremo un solo risultato normalmente, mentre per solo per la root uno SCONS.

	# il primo puo' essere il conservatore, se non lo e' lo metto tra i produttori
	$scons = $sth->fetchrow_hashref;
	if (SCELSI_SCONS ne $scons->{relationship_type}) {
	    push (@$prod, $scons);
	    $scons=undef;
	}
	while (my $p = $sth->fetchrow_hashref) {
	    push(@$prod, $p);
	}
	$sth->finish;

	# patch per quando non ci sono produttori associati alla scheda
	unless (scalar @$prod) {
	    push(@$prod, {entity_name=>'Fondazione Scelsi', entity_uuid=>'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', relationship_type=>SCELSI_PROD});
	}
	# patch per quando non c'e' alcun sogg. conservatore (associato alla root)
	unless ($obj->{parent_id} || $scons) {
	    $scons = {entity_name=>'Fondazione Scelsi', entity_uuid=>'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', relationship_type=>SCELSI_SCONS};
	}
    }

    # per Scelsi non seguo ca_objects_x_occurencies in quanto mancano gli strumenti

    # come otherlevel:
    # se ca_objects.type_id = 23 (serie) prendo il valore dell'attributo genreform,
    #  diversamente item_value estratto dalla prima query.


    my $struct = _perl_ead($obj, $attrs, $prod, $scons);

    my $wfp;
    if (exists $ENV{PERLDB_PIDS} ) {
	open($wfp, '>', '/tmp/scelsi_debug.log') || die("Cannot open log");
	print $wfp "struct: "   . Dumper($struct)  . "\n\n";
	print $wfp "obj: "      . Dumper($obj)     . "\n\n";
	print $wfp "attrs: "    . Dumper($attrs)   . "\n\n";
	print $wfp "scons: "    . Dumper($scons)   . "\n\n";
	print $wfp "prod: "     . Dumper($prod)    . "\n\n";
	print $wfp "******************\n";
    }

    my $ead = Promemoria::SAN::EAD::build_XML($struct);

    if (exists $ENV{PERLDB_PIDS} ) {
	print $wfp "ead: "      . Dumper($ead)     . "\n\n";
	print $wfp "******************\n";
	close($wfp);
    }
    return $ead->to_xml_fragment();
}

sub _parse_date {
    my ($input) = @_;
    if ($input =~ /(\d{2}).(\d{2}).(\d{4}).*\-.*(\d{2}).(\d{2}).(\d{4})/) {
	# range di date da girare al contrario:
	return "$3$2$1/$6$5$4";
    } elsif ($input =~ /(\d{2}).(\d{2}).(\d{4})/) {
	return "$3$2$1";
    } else {
	return "s.d.";
    }
}

=head2 ListRecords


=cut

sub ListRecords {
    my ($dbh, $resumptionToken, $metadataPrefix, $from, $until) = @_;
    my @records;

    die("$dbh undef") unless ($dbh);

    if ('ead-san' eq $metadataPrefix) {
	my $structs = _listrecords_ead($dbh, $resumptionToken, $from, $until);
	if ($structs) {
	    # consumo l'array per rilasciare RAM
	    while (my $struct = shift @$structs) {
		my $ead = Promemoria::SAN::EAD::build_XML($struct);
	        push(@records, 
		 # Se vogliamo o dobbiamo aggiungere l'header c'e' da fornire una data (di aggiornamento) del record
		     "<header>" .
		       "<identifier>" . $ead->archdesc->did->unitid . "</identifier>" .
		       "<datestamp>" . '2015-09-05' . "</datestamp>" .
		     "</header>" . 
		 # diversamente lasciamo solo metadata ed i dati contenuti
		     "<metadata>".$ead->to_xml_fragment()."</metadata>");
	    }
	} else {
	    # no result
	    return;
	}
    }

    if ('eac-san' eq $metadataPrefix) {
	my $structs = _listrecords_eac($dbh, $resumptionToken, $from, $until);
	if ($structs) {
	    # consumo l'array per rilasciare RAM
	    while (my $struct = shift @$structs) {
		# potremo scommentare quando esisterà il modulo per EAC
		my $eac = Promemoria::SAN::EAC::build_XML($struct);
	        push(@records, 
		 # Se vogliamo o dobbiamo aggiungere l'header c'e' da fornire una data (di aggiornamento) del record
#		     "<header>" .
#		       "<identifier>" . $eac->archdesc->did->unitid->value() . "</identifier>" .
#		       "<datestamp>" . '2015-09-05' . "</datestamp>" .
#		     "</header>" . 
		 # diversamente lasciamo solo metadata ed i dati contenuti
		     "<metadata>".$eac->to_xml_fragment()."</metdata>");
	    }
	} else {
	    # no result
	    return;
	}
    }
    return \@records;
}


=head2 _listrecords_ead

Dovrebbe esportare i dati in modo da esporre prima il padre dei figli.
Un criterio puo' essere quello di order by hier_parent_id,object_id.
Per costruzione delle schede in collectiveaccess in teoria potrebbe bastare order by object_id.

Devo ancora implementare le condizioni from e until nelle query.

=cut

sub _listrecords_ead {
    my ($dbh, $resumptionToken, $from, $until) = @_;
    my $eads;

    my %objects;
    {
	# assumo che se il padre non è visibile non lo sia manco il figlio
	# per cui non passo dal ca_objects del parent, e accedo direttamente ai suoi metadati.
    
	my $sql = q[
SELECT o.object_id, o.idno, o.type_id, l.name, l.is_preferred, li.item_value, av.value_longtext1 as parent_uuid
  FROM 
       ca_object_labels l,
       ca_list_items as li,
       ca_objects o
       -- aggiungo i dati per estrarre la relazione con il padre (eventuale)
       left join ca_attributes as a on (o.parent_id=a.row_id and a.table_num=? and a.element_id=?)
       left join ca_attribute_values as av on (a.attribute_id=av.attribute_id and av.element_id=?)  -- 479
 WHERE o.object_id = l.object_id and o.access = 1 and o.deleted=0 and o.type_id=li.item_id
	 and l.is_preferred=1
ORDER BY o.object_id,l.is_preferred desc, l.name
];

	my $sth = $dbh->prepare($sql);
	$sth->execute(CA_OBJECTS_TABLE_NUM, PERM_ELEMENT_ID, PERM_ELEMENT_ID);

	unless ($sth->rows) {
	    return $eads;
	}

	%objects = %{$sth->fetchall_hashref('object_id')};

	$sth->finish;
    }

    my %objects_attrs;
    {
	my %attrs = ();
	# estraiamo tutti gli attributi che servono:

	my @attributi = qw/ genreform data_range scopecontent consistenza perm_id/;

	my $sql = q[
SELECT o.object_id,me.element_code, av.value_longtext1 as value
  FROM ca_objects o, 
       ca_attributes a,
       ca_attribute_values av, 
       ca_metadata_elements me 
 WHERE
       o.object_id = a.row_id and
       a.attribute_id = av.attribute_id and
       a.element_id = me.element_id and
       o.deleted = 0 and
       o.access = 1 and
       a.table_num = ? and
       -- tolgo gli attributi con valori nulli o vuoti
       av.value_longtext1 is not null AND 
       av.value_longtext1 <> '' and
       me.element_code in ( '] . join("','", @attributi) . q[' )
ORDER BY o.object_id,me.element_code];

	# @attributi e' una variabile locale, non puo' avvenire alcun SQL injection da qui e
	# quindi mi fido a metterlo inline nella query

	my $sth = $dbh->prepare($sql);
	die('$sth undef') unless($sth);
	$sth->execute(CA_OBJECTS_TABLE_NUM);

	unless ($sth->rows > 0) {
	    die("no result:\n $sql \n (CA_OBJECTS_TABLE_NUM) \n");
	}


	# non ci sono multivalore
	my $obj_id;
	my $attrs={};
	while (my $ar = $sth->fetchrow_hashref) {
	    if (defined $obj_id && ($obj_id != $ar->{object_id})) {
		$objects_attrs{$obj_id} = $attrs;
		$attrs = {};
	    }
	    $obj_id = $ar->{object_id};
	    $attrs->{$ar->{element_code}} = $ar->{value};
	}
	$objects_attrs{$obj_id} = $attrs if (defined $obj_id);
	$sth->finish;
    }

    my %objects_entities=();
    {
	#
	# prendiamo le entità correlate.
	#

	my $sql = q(
SELECT coe.object_id, el.displayname as entity_name, av.value_longtext1 as entity_uuid, coe.type_id as relationship_type
  FROM ca_objects_x_entities as coe, ca_entity_labels as el, ca_attributes as a, ca_attribute_values as av
 WHERE 
       el.entity_id=coe.entity_id and
       a.table_num=? and -- 20
       a.row_id=coe.entity_id and
       av.element_id=a.element_id and
       av.attribute_id=a.attribute_id and
       av.element_id=? and      -- 479 o CA_ENTITIES_TABLE_NUM
       coe.type_id in (?,?) and -- 275 e 237
       el.is_preferred
ORDER BY coe.object_id,coe.type_id desc
);


	my $sth = $dbh->prepare($sql);
	$sth->execute(CA_ENTITIES_TABLE_NUM, PERM_ELEMENT_ID, SCELSI_SCONS, SCELSI_PROD);
	# avremo un solo risultato normalmente, mentre per solo per la root uno SCONS.

	my $obj_id;
	my $scons;
	my $prod;
	while ( my $e = $sth->fetchrow_hashref ) {
	    if (defined $obj_id && ($obj_id != $e->{object_id})) {
		objects_entities{$obj_id} = {produttori=>$prod, conservatore=>$scons};
		$scons = '';
		$prod  = [];
	    }
	    $obj_id = $e->{object_id};
	    if (SCELSI_PROD == $e->{relationship_type}) {
		push (@$prod, {entity_name=>$e->{entity_name}, entity_uuid=>$e->{entity_uuid}});
	    }
	    if (SCELSI_SCONS == $e->{relationship_type}) {
		# 2015-09-14 c'è una scheda del conservatore che prima mancava nel db scelsi.
		$scons={entity_name=>$e->{entity_name}, entity_uuid=>$e->{entity_uuid}};
	    }
	}
	$sth->finish;
	if (defined $obj_id) {
	    $objects_entities{$obj_id}{produttori}=$prod if (scalar @$prod);
	    $objects_entities{$obj_id}{conservatore}=$scons if (defined $scons);
	}

	# patch per quando non ci sono produttori associati alla scheda
	unless (defined $prod && scalar @$prod) {
	    push(@$prod, {entity_name=>'Fondazione Scelsi', entity_uuid=>'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', relationship_type=>SCELSI_PROD});
	}

	# patch per quando non c'e' alcun sogg. conservatore (associato alla root)
	# il soggetto conservatore lo associamo solo agli objects di root
	# che magari non ci sono tra gli oggetti risultanti da questa interrogazione
	# vediamo:

	my @roots = grep {!defined $objects{$_}{parent_uuid}} keys (%objects);
	$DB::single=1;
	if (scalar @roots &&  !$scons) {
	    # devo ancora associarlo solo ai record in @roots
	    $scons = {entity_name=>'Fondazione Scelsi', entity_uuid=>'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', relationship_type=>SCELSI_SCONS};
	    for (@roots) {
		$objects_entities{$_}{conservatore}=$scons;
	    }
	}
    }

    # per Scelsi non seguo ca_objects_x_occurencies in quanto mancano gli strumenti

    $eads = [];

    for my $object_id (sort {$a <=> $b} keys %objects) {
	my $obj     = $objects{$object_id};
	my $attrs   = $objects_attrs{$object_id};
	my ($prod, $scons);
	if (exists $objects_entities{$object_id}) {
	    $prod    = $objects_entities{$object_id}{produttori} if (exists $objects_entities{$object_id}{produttori});
	    $scons   = $objects_entities{$object_id}{conservatore} if (exists $objects_entities{$object_id}{conservatore});
	}
	my $struct  = _perl_ead($obj, $attrs, $prod, $scons);
	push(@$eads,  $struct);
    }

    return $eads;
}


sub _perl_ead {
    my ($obj, $attributi, $produttori, $conservatore) = @_;
    my %attrs = (defined $attributi ? %$attributi : die("obj non ha attributi: " . Dumper($obj)));
    my @prod = (defined $produttori ? @$produttori : ());

    # costruisco gli argomenti in modo dinamico se hanno valore o se
    # devo assegnare loro un valore di default.
    my %args = ();

    if ((exists $prod[0]) && (exists $prod[0]->{entity_uuid})) {
	# da gestire produttori multipli (da fare il loop e creare un array di value=>...)
	$args{origination} = $prod[0]->{entity_uuid};
    }

    if (exists $obj->{parent_uuid} && (defined $obj->{parent_uuid} )) {
	$args{relatedmaterial} = {attrs=>{archref=>$obj->{parent_uuid}}};
    } else {
	# forse se manca il parent deve puntare a se stesso... verificare
    }

    if (exists $attrs{scopecontent} && defined $attrs{scopecontent}) {
	$args{abstract} = {
		attrs => {langcode=>'it_IT'},
		value=> $attrs{scopecontent},
	};
    }

    # se ci fossero strumenti... 
    if (0) {
	$args{otherfindaid} = {
		# extref=> $attrs{...},
	};
    }

    # come otherlevel:
    # se ca_objects.type_id = 23 (serie) prendo il valore dell'attributo genreform,
    #  diversamente item_value estratto dalla prima query.

    if (23 == $obj->{type_id}) {
	$args{otherlevel}=$attrs{genreform};
    } else {
	$args{otherlevel}=$obj->{item_value};
    }
    if (exists $attrs{data_range} && ('' ne $attrs{data_range})) {
	$args{unitdate}={
	    attrs => {
		normal   => _parse_date($attrs{data_range}), 
		datechar => 'principale',
	    }, 
	    value => $attrs{data_range},
	};
    } else {
	$args{unitdate} = {
	    attrs => {
		normal   => '00000000',
		datechar => 'non indicata',
	    }, 
	    value => 's.d.',
	};
    }

    if (defined $conservatore && (exists $conservatore->{entity_uuid})) {
	$args{repository} = {
	    attrs => {
		id=>$conservatore->{entity_uuid},
		label=>$conservatore->{entity_name},
	    },
	    value=>$conservatore->{entity_name},
	};
    } else {
	# ci vuole di serie per specifiche:
	$args{repository} = {
	    attrs => {
		id=>'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
		label=>'Fondazione Scelsi',
	    },
	    value=>'Fondazione Isabella Scelsi',
	};
    }

    my $struct = Promemoria::SAN::EAD::perl_ead(
	    %args,
	    # origination =>$prod[0]->{entity_uuid},
	    unitid    => {
		attrs =>{
		    type=>'Archivio Fondazione Isabella Scelsi',
		    identifier=>'http://demo-scelsi.promemoriagroup.com/index.php/'},
		value =>$attrs{perm_id},
	    },
	    unittitle => {
		attrs => {type=>'principale'},
		value => $obj->{name},
	    },
	);
    return $struct;
}

=head2 CostruisciEntita

Gli eac e gli scons hanno tracciati dati diversi e si distinguono con il type_id.

=cut

sub CostruisciEntita {
    my ($dbh, $object_id, $metadataPrefix) = @_;
    return;
}

1;
