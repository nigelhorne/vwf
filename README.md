vwf
===

Versatile Web Framework - easily build a website to support different languages and client platforms

Licenced under GPL2.0 for personal use only.

What This Does:
---------------

VWF is a framework to easily display web pages tailored to the wishes
of the browser, e.g. language to use and mobile/web content. It supports
Template Toolkit (http://template-toolkit.org/) and HTML files.

The idea is call index.pl which will then automatically display
the correct index.htm (or index.tmpl) file based on the browser language
setting (e.g. en-GB), and type (e.g. mobile).

By putting the pages in a directory hierarchy new versions can be quickly
added for mobile/robot (i.e. search engine) use in addition to web pages,
and allow new languages to be added easily.

The content directory hierarchy is of the format
.../language/region/[web|mobile|robot]/VWF/filename.[html|tmpl].
Language and region are determined by the browser settings. If the template
isn't found there it looks in
.../language/[web|mobile|robot]/VWF/filename.[html|tmpl], and if not
there it looks in ../[web|mobile|robot]/VWF/filename.[html|tmpl].
The fall back is web, so if a mobile browser visits and there is no specific
mobile page to display then the web page will be displayed.

To make it easier to understand, here's an example.  Your primary index page
for the Web could be held in .../web/VWF/index.tmpl, the mobile page in
.../mobile/VWF/index.tmpl and the page for search engines in
.../robot/VWF/index.tmpl.  Presumably that page would be written in U.S.
English. If you were to do a version in Spanish, that would be in
.../es/web/VWF/index.tmpl and so on.  And a version in British English would be
in .../en/gb/web/VWF/index.tmpl (NOT .../en/web/index.tmpl otherwise U.S.
readers would be directed there).

How To Install and Use:
-----------------------

Firstly you'll need to ensure that your index page points to the VWF delivery
page for example by adding these to your .htaccess file:
RedirectPermanent	/index.html	http://[YOURSITE]/cgi-bin/index.pl
RedirectPermanent	/index.htm	http://[YOURSITE]/cgi-bin/index.pl

Next copy the contents of the lib directory to /usr/lib/VKF (or a place
of your choice).

Next modify index.pl changing the "use usr/lib/VKF" directive to point to
where you've installed page.pm.

Next create a directory hierarchy containing the pages to be displayed, e.g.
.../web/en/VWF/index.html
.../web/en/gb/VWF/index.html
.../web/fr/VWF/index.html
.../mobile/en/VWF/index.html

You'll need to create cgi-bin files for each of your page sets (e.g. create
foo.pl for .../web/*/*/foo.html). That's easier than you think because most
of the time you'll use index.pl as a template and change the two places
that VWF::index appear to VWF::foo.

TODO: Add sample files
FIXME: It would be more logical to be .../VWF/web/index.htm than
	.../web/VWF/index.htm

Nigel Horne (njh@bandsman.co.uk)
