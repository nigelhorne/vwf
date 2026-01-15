<?xml version="1.0"?>
<config>
	<memory_cache>
		<driver>Null</driver>
	</memory_cache>
	<disc_cache>
		<driver>Null</driver>
	</disc_cache>
	<SiteTitle>
		<English>Sample VWF site</English>
		<Default>Sample VWF site</Default>
	</SiteTitle>
	<root_dir>/Users/njh/src/njh/vwf</root_dir>

	<!--
		Get keys from https://www.google.com/recaptcha/admin
	-->
	<recaptcha>
		<site_key>YOUR_SITE_KEY_HERE</site_key>
		<secret_key>YOUR_SECRET_KEY_HERE</secret_key>
		<enabled>1</enabled>
	</recaptcha>

	<security>
		<rate_limiting>
			<!--  Hard limit - block completely -->
			<max_requests_hard>150</max_requests_hard>
			<!-- Soft limit - show CAPTCHA -->
			<max_requests>100</max_requests>
			<time_window>60s</time_window>
			<!-- 5 minutes after successful CAPTCHA -->
			<captcha_bypass_duration>300s</captcha_bypass_duration>
		</rate_limiting>
		<!-- CGI::IDS threshold -->
		<ids_threshold>50</ids_threshold>
		<csrf>
			<!-- Generate CSRF token for forms -->
			<enable>1</enable>
			<secret>default_secret</secret>
		</csrf>
	</security>
</config>
