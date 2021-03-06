=xml
<document title="Server Side XSLT Module">
    <synopsis>
        Does XSL processing using the Gnome LibXSLT libraries
    </synopsis>
    <todo>
        Add alternatives to Gnome LibXSLT/XML
    </todo>
    <todo>
       Drop cached styles after a given time period, to prevent rarely-used styles from permanentally hogging memory.
    </todo>
=cut
package ssxslt;

#1;
#__END__

# import oyster libraries
use oyster 'module';
use exceptions;

#
# Initialization
#

our ($disable_ssxslt, $xml_parser, $xslt_parser, %styles, %style_parse_times, $loaded);

# load module
sub load {

    # server side xml/xslt libraries
    try {
        require XML::LibXSLT;
        require XML::LibXML;
    }
    catch 'perl_error', with {
        $disable_ssxslt = 1;
        log::status('Server side XSLT module ignored.  Required libraries are not available.'); # unless $CONFIG{'debug'};
    };
    
    unless ($disable_ssxslt) {

        # create xml/xslt processor objects
        $xml_parser  = XML::LibXML->new();
        $xslt_parser = XML::LibXSLT->new();
    
        $loaded = 1;
    }
}

# ----------------------------------------------------------------------------
# Hooks
# ----------------------------------------------------------------------------

event::register_hook('request_init', 'hook_request_init', 110);
sub hook_request_init {
    return if $disable_ssxslt == 1;

    # parse the user agent to get a rendering engine and version
    oyster::parse_user_agent();

    # figure out of the user's engine and version can handle xml/xslt
    my ($engine, $version, $handler)  = @REQUEST{ 'ua_render_engine', 'ua_render_engine_version', 'handler' };

    if (exists $INPUT{'ssxslt'} or $CONFIG{'force_ssxslt'} == 1) { $REQUEST{'server_side_xslt'} = 1 } # developer ssxslt override
    elsif ($engine eq 'trident' and $version > 5.5 and $ENV{'HTTPS'} ne 'on') { return } # XSL in IE older than 9.0.10 fails over HTTPS
    elsif ($engine eq 'trident' and $version > 9 and $ENV{'HTTPS'} eq 'on') { return }
    elsif ($engine eq 'presto' and $version >= 9) { return }
    elsif ($engine eq 'gecko') { return }
    elsif ($engine eq 'webkit') { return }
    elsif ($engine eq 'khtml') { return }
    else { $REQUEST{'server_side_xslt'} = 1 }

    # capture output
    if (exists $REQUEST{'server_side_xslt'}) {

        # if this is the first ssxslt request, load gnome's xml libs
        unless ($loaded == 1) {
            load();
            if ($disable_ssxslt == 1) {
                delete $REQUEST{'server_side_xslt'};
                return;
            }
        }

        # start an output buffer
        $mimetype = $style::styles{$REQUEST{'style'}}->{'output'} eq 'xhtml' ? 'application/xhtml+xml' : 'text/html';
        $REQUEST{'mime_type'} = $engine eq 'trident' ? 'text/html' : $mimetype ; # IE does not support xhtml as xml, only html as sgml
        buffer::start();
    }
}

event::register_hook('request_finish', 'hook_request_finish', -110);
sub hook_request_finish {
    return unless exists $REQUEST{'server_side_xslt'};
    my ($buffer, $source);

    my $buffer = buffer::end_clean();
    
    if ($REQUEST{'handler'} ne 'ajax') {
        $buffer =~ s/^.+\n.+\n//; # strip first two lines out (xml version and stylesheet)
    
        utf8::upgrade($buffer); # experimental fix for non UTF-8 data choking LibXML
    
        try {
           #log::debug('hi');
           $source = $xml_parser->parse_string($buffer);
           #log::debug('hi2u2');
        }
        catch 'perl_error', with {
           log::error("Error parsing XML on URL '$ENV{REQUEST_URI}': $@");
           #throw 'perl_error', "Error parsing XML on URL '$ENV{REQUEST_URI}': $@";
        };

        my $style_id = $REQUEST{'style'};

        # reparse server_base.xsl if necessary
        _parse_server_base($style_id) if (!exists $styles{$style_id} or ($oyster::CONFIG{'compile_styles'} and file::mtime("$CONFIG{site_path}styles/$style_id/server_base.xsl") > $style_parse_times{$style_id}));

    # TODO: proper errors for the end user if something goes wrong
    # TODO: should be a debugging switch for the evals

        # transform xml using the current style
        my $style = eval { $styles{$style_id}->transform($source) };
        if ($@) {
            log::error("Error parsing style '$style_id' url '$ENV{REQUEST_URI}': $@");
            return;
        }

        # print output
        print $styles{$style_id}->output_string($style);
        print "\n<!-- Full Execution Time (with server side XSLT): " . sprintf('%0.5f', Time::HiRes::gettimeofday() - $REQUEST{'start_time'}) . " sec -->\n";
    }
    
    else {
        print $buffer;
    }
}

sub _parse_server_base {
    my $style_id = shift;
    return unless -e "$CONFIG{site_path}styles/$style_id/server_base.xsl";
    $style_parse_times{$style_id} = time(); # TODO: if file::mtime is changed to gmt, this will have to be changed to datetime::gmtime()
    eval { $styles{$style_id} = $xslt_parser->parse_stylesheet($xml_parser->parse_file("$CONFIG{site_path}styles/$style_id/server_base.xsl")) };
    log::error("Error parsing style' $CONFIG{site_path}styles/$style_id/server_base.xsl': $@") if ($@ and $CONFIG{'debug'});
}

=xml
</document>
=cut

1;

# Copyright BitPiston 2008