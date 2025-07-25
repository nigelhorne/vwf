VWF
===

Versatile Web Framework - an MVC framework to rapidly build a responsive website
that supports different languages, databases and client platforms.

Licenced under GPL2.0 for personal use only.

# What This Does

VWF is a web application framework to easily display web pages tailored to the
wishes of the browser, e.g. language to use and mobile/web content.
It supports Template Toolkit (http://template-toolkit.org/),
text and HTML files.
The framework handles web requests using FastCGI and offers dynamic page rendering, access control (including rate limiting), and caching.

The idea is to create index.fcgi which will then automatically display
the correct index.htm (or index.tmpl) file based on the browser language
setting (e.g. en-GB) and type (e.g. mobile). By putting the pages in a
directory hierarchy new versions can be quickly added for
mobile/robot/search-engine use in addition to web pages, and allow new
languages to be added easily.

The content directory hierarchy is of the format
.../language/region/[web|mobile|robot|search]/filename.[html|tmpl|txt].
Language and region are determined by the browser settings. If the template
isn't found there it looks in
.../language/[web|mobile|robot|search]/filename.[html|tmpl|txt], and if not
there it looks in ../[web|mobile|robot|search]/filename.[html|tmpl|txt].
The fall back is web, so if a mobile browser visits and there is no specific
mobile page to display then the web page will be displayed.

To make it easier to understand, here's an example.  Your primary index page
for the Web could be held in .../web/index.tmpl, the mobile page in
.../mobile/index.tmpl and the page for search engines in
.../search/index.tmpl.  Presumably that page would be written in U.S.
English. If you were to do a version in Spanish, that would be in
.../es/web/index.tmpl and so on.  And a version in British English would be
in .../en/gb/web/index.tmpl (NOT .../en/web/index.tmpl otherwise U.S.
readers would be directed there).

Files ending in .tmpl will be sent using the Template Toolkit, files ending
with .html or .htm will be sent as is, and files ending in .txt will
be sent as is with the Content-Type header set to text/plain.

Data stored in the files .../databases/ is be made available to
the display packages and hence to the templates. CSV, XML and SQLite format
files are supported.

# How To Install and Use

## Overview
1. Install dependencies: `cpanm -i lazy && perl -Mlazy cgi-bin/page.fcgi ''`
2. Run the script: `./page.fcgi`
3. Test from the command line: `LANG=en_GB root_dir=$(pwd) cgi-bin/page.fcgi page=meta_data`

## Installation
Firstly you'll need to ensure that your index page points to the VWF delivery
page for example by adding these to your .htaccess file:

    RedirectPermanent	/index.html	http://[YOURSITE]/cgi-bin/index.fcgi
    RedirectPermanent	/index.htm	http://[YOURSITE]/cgi-bin/index.fcgi

Next copy the contents of the lib directory to /usr/lib/VMF (or a place
of your choice), and the sample index.fcgi of the cgi-bin directory to /cgi-bin
in your webroot.

Next modify index.fcgi changing the "use /usr/lib" directive to point to
where you've installed the VWF lib files such as page.pm.  Use /usr/lib, for
example, if you put it into /usr/lib/VWF/page.pm

Next create a directory hierarchy containing the pages to be displayed, e.g.

    .../web/en/index.tmpl
    .../web/en/gb/index.tmpl
    .../web/fr/index.tmpl
    .../mobile/en/index.tmpl

Next install any dependancies from CPAN, such as CGI::Lingua, CGI::Buffer,
CGI::IDS, Data::Throttler, Config::Auto and Template.

You'll need to create cgi-bin files for each of your page sets (e.g. create
foo.fcgi for .../web/*/*/foo.html). That's easier than you think because most
of the time you'll use index.fcgi as a template and change the two places
that VWF::index appear to VWF::foo.

Now you need to tell VWF where to find the configuration files. Create a
conf directory in a place such as /usr/lib/conf if the libaries went into
/usr/lib/VMF.

The configuration file takes the form of:

    root_dir /full/path/to/template directory
    memory_cache: where short-term volatile information is stored, such as the country of origin of the client.
    disc_cache: where long-term information is stored, such as copies of output to see is HTTP 304 can be returned. 

For example, if your index.tmpl file lives in /usr/lib/example.com/templates/VWF/web/index.tmpl,
then you would add 'root_dir /usr/lib/example.com'.

The name of the configuration file the sitename, e.g. /usr/lib/conf/example.com.

Finally change conf/index.l4pconf to the logging mechanism of your choice.

The database system is yet to be documented, but essentially it provides
a simple way to include dynamic data in your templates.

Look everywhere in the code and configuration files for the string "example.com" and replace that to suit.

## Usage
VWF is smart enough that you can debug from the command line before you deploy.
Interesting possiblilties include:

    perl -c -Ilib cgi-bin/page.fcgi
    cgi-bin/index.fcgi --mobile
    cgi-bin/index.fcgi lang=fr
    cgi-bin/index.fcgi key=value
    root_dir=$(pwd) cgi-bin/page.fcgi --search-engine page=index lint_content=0

## Worked Example

I set up http://bandsman.mooo.com/~njh to print a simple Hello, World.

The file layout is:

    $ find ~njh/VWF/
    /home/njh/VWF/
    /home/njh/VWF/page.pm
    /home/njh/VWF/index.pm
    /home/njh/VWF/table.pm
    $ find /home/njh/public_html/
    /home/njh/public_html/
    /home/njh/public_html/index.html
    /home/njh/public_html/cgi-bin
    /home/njh/public_html/cgi-bin/index.fcgi
    /home/njh/public_html/.htaccess
    $ find /home/njh/bandsman.mooo.com/
    /home/njh/bandsman.mooo.com/
    /home/njh/bandsman.mooo.com/templates
    /home/njh/bandsman.mooo.com/templates/VWF
    /home/njh/bandsman.mooo.com/templates/VWF/index.html
    /home/njh/bandsman.mooo.com/databases/index.db

# Caveats
Every time you upload a new site ensure that you remove the "save_to" directory, since that contains
cached copies of pages that will be inconsistent with the new site.

FIXME: Configuration files should be in .../conf, not .../lib/conf

# Updates
git clone https://github.com/nigelhorne/vwf.git

Nigel Horne, `<njh at bandsman.co.uk>`
