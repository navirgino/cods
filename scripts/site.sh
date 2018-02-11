##############################################################################
# Site management script
#
# This script contains functions for site management, and will run the
# appropriate function based on the arguments passed to it. Most of the
# functionality here is for setting up nginx and tomcat to host sites, as well
# as enabling https for sites.
##############################################################################

list_sites() {
	ssh $user@$ip 'ls -1 /etc/nginx/sites-available' | grep -v '^default$'
}

enable_git_deploment() {
	domain=$1
	springboot=$2
	[[ -z $domain ]] && die 'Error in enable_git_deployment: $domain not specified'
	echo "Setting up git deployment..."

	# figure out whether we have a java site or a static one
	ssh -t $user@$ip "grep proxy_pass /etc/nginx/sites-available/$domain" >/dev/null
	if [[ $? -eq 0 ]] ; then
		template=post-receive.sh
	else
		template=post-receive-static.sh
	fi

	ssh -t $user@$ip "
	mkdir /srv/${domain}
	cp /srv/.templates/config /srv/${domain}/config
	git init --bare --shared=group /srv/${domain}/repo.git
	cp /srv/.templates/$template /srv/${domain}/repo.git/hooks/post-receive
	sed -i -e s/{{site}}/$domain/g /srv/${domain}/repo.git/hooks/post-receive
	chmod +x /srv/${domain}/repo.git/hooks/post-receive
	"
	if [[ -n $springboot ]] ; then
		ssh $user@$ip "
		sed -i -e '/application.properties/ { s/^# //g; }' /srv/${domain}/config
		echo '# put your configuration here' > /srv/${domain}/application.properties
		"
	fi
	echo "git deployment configured!"
	echo "Here is your deployment remote:"
	echo
	echo "	$user@$ip:/srv/${domain}/repo.git"
	echo
	echo "You can run something like:"
	echo
	echo "	git remote add production $user@$ip:/srv/${domain}/repo.git"
	echo
	echo "To add the remote."
}

create_site() {
	while [[ $# -gt 0 ]] ; do
	    arg=$1 ; shift
	    case $arg in
	        -d|--domain) domain=$1 ; shift;;
	        --domain=*) domain=${arg#*=};;
			--enable-ssl) ssl=yes;;
			--sb|--spring-boot) springboot=yes;;
	        *) echo "Unknown argument: $arg" ; exit 1;;
	    esac
	done
	if [[ -z $domain ]] ; then
		cat <<-.
		Setup up the server to host a new site. Optionally also enable ssl or
		setup the site as a spring boot site (this just enables some common
		configuration).
		You should only enable ssl if you know your DNS records are properly
		configured, otherwise you can do this with the separate 'enablessl'
		site subcommand.

		-d|--domain <domain> -- domain name of the site to create
		--enable-ssl         -- (optional) enable ssl for the setup site
		--spring-boot        -- (optional) designate that this is a spring boot site

		Example:
		    $(basename $0) site create -d example.com
		    $(basename $0) site create --domain=example.com --enable-ssl
		.
		die
	fi

	if list_sites | grep "^$domain$" > /dev/null ; then
		echo 'It looks like that site is already setup. Doing nothing.'
		echo 'If you wish to re-create the site, first remove the site, then'
		echo 're-create it.'
		exit 1
	fi

	# verify dns records
	if [[ "$(dig +short ${domain} | tail -n 1)" != $ip ]]; then
		echo 'It looks like the dns records for that domain are not setup to'
		echo 'point to your server.'
		confirm "Are you sure you want to setup ${domain}?" || die 'Aborting...'
	fi

	echo "Setting up ${domain}..."

	ssh -t $user@$ip "
	set -e
	# tomcat config
	echo 'Configuring tomcat...'
	sudo perl -i -pe 's!^.*--## Virtual Hosts ##--.*\$!$&\n\
	<Host name=\"${domain}\" appBase=\"${domain}\" unpackWARs=\"true\" autoDeploy=\"true\" />!' \
		/opt/tomcat/conf/server.xml
	sudo mkdir -p /opt/tomcat/${domain}
	sudo chown -R tomcat:tomcat /opt/tomcat/${domain}
	sudo chmod -R g+w /opt/tomcat/${domain}
	echo 'Restarting tomcat...'
	sudo systemctl restart tomcat

	sudo mkdir -p /var/www/${domain}/uploads
	sudo chmod g+rw /var/www/${domain}/uploads
	sudo chown -R tomcat:tomcat /var/www/${domain}/uploads

	# nginx config
	echo 'Configuring nginx...'
	sudo cp /srv/.templates/site.nginx.conf /etc/nginx/sites-available/${domain}
	sudo sed -i -e s/{{domain}}/${domain}/g /etc/nginx/sites-available/${domain}
	sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/${domain}
	echo 'Restarting nginx...'
	sudo systemctl restart nginx
	"
	[[ $? -eq 0 ]] && echo "${domain} created!"

	enable_git_deploment $domain $springboot
	if [[ $ssl == yes ]] ; then
		echo "Enabling SSL for $domain..."
		enable_ssl --domain $domain
	fi
}

create_static_site() {
	while [[ $# -gt 0 ]] ; do
	    arg=$1 ; shift
	    case $arg in
	        -d|--domain) domain=$1 ; shift;;
	        --domain=*) domain=${arg#*=};;
	        *) echo "Unknown argument: $arg" ; exit 1;;
	    esac
	done
	if [[ -z $domain ]] ; then
		cat <<-.
		Create a static site.

		-d|--domain <domain> -- domain name of the site to create
		.
		die
	fi

	ssh -t $user@$ip "
	set -e
	echo 'Configuring nginx...'

	sudo mkdir -p /var/www/${domain}
	sudo chgrp --recursive www-data /var/www/${domain}
	sudo chmod g+srw /var/www/${domain}

	sudo cp /srv/.templates/static-site.nginx.conf /etc/nginx/sites-available/${domain}
	sudo sed -i -e s/{{domain}}/${domain}/g /etc/nginx/sites-available/${domain}
	sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/${domain}
	echo 'Restarting nginx...'
	sudo systemctl restart nginx
	"
	[[ $? -eq 0 ]] && echo "${domain} created!"

	enable_git_deploment $domain
	if [[ $ssl == yes ]] ; then
		echo "Enabling SSL for $domain..."
		enable_ssl --domain $domain
	fi
}

enable_ssl() {
	while [[ $# -gt 0 ]] ; do
	    arg=$1 ; shift
	    case $arg in
	        -d|--domain) domain=$1 ; shift;;
	        --domain=*) domain=${arg#*=};;
	        *) echo "Unknown argument: $arg" ; exit 1;;
	    esac
	done
	if [[ -z $domain ]] ; then
		cat <<-.
		Enable https for a site. Before running this command, you should make
		sure that the DNS records for your domain are configured to point to
		your server, otherwise this command *will* fail.

		-d|--domain <domain> -- domain name of the site to enable https for

		Example:
		    $(basename $0) site enablessl -d example.com
		.
		die
	fi

	# figure out whether we have a java site or a static one
	ssh -t $user@$ip "grep proxy_pass /etc/nginx/sites-available/$domain" >/dev/null
	if [[ $? -eq 0 ]] ; then
		template=ssl-site.nginx.conf
	else
		template=static-ssl-site.nginx.conf
	fi

	echo 'Requesting SSL certificate... (this might take a second)'
	ssh -t $user@$ip "
	set -e
	if egrep 'ssl\s*on; /etc/nginx/sites-available/$domain' >/dev/null ; then
		echo 'It looks like SSL is already setup for $domain'
		echo 'Doing nothing.'
		exit 1
	fi
	mkdir -p /srv/${domain}
	sudo letsencrypt certonly\
		--authenticator webroot\
		--webroot-path=/var/www/${domain}\
		--domain ${domain}\
		--agree-tos\
		--email $email\
		--renew-by-default >> /srv/letsencrypt.log

	echo 'Setting up nginx to serve ${domain} over https...'
	sudo cp /srv/.templates/$template /etc/nginx/sites-available/${domain}
	sudo sed -i -e s/{{domain}}/${domain}/g /etc/nginx/sites-available/${domain}
	sudo systemctl restart nginx
	"

	[[ $? -eq 0 ]] && echo "https enabled for ${domain}!"
}

remove_site() {
	while [[ $# -gt 0 ]] ; do
	    arg=$1 ; shift
	    case $arg in
	        -d|--domain) domain=$1 ; shift;;
	        --domain=*) domain=${arg#*=};;
	        *) echo "Unknown argument: $arg" ; exit 1;;
	    esac
	done
	if [[ -z $domain ]] ; then
		cat <<-.
		Remove a site from the server

		-d|--domain <domain> -- name of the site to remove

		Example:
		    $(basename $0) site remove -d example.com
		.
		die
	fi

	list_sites | grep "^$domain$" >/dev/null || die "It looks like $domain does not exist. Aborting..."
	# confirm deletion
	confirm "Are you sure you want to remove ${domain}?" || die 'domain not removed.'

	ssh -t $user@$ip "
	sudo sed -i -e '/${domain}/d' /opt/tomcat/conf/server.xml

	sudo rm -f /etc/nginx/sites-available/${domain}
	sudo rm -f /etc/nginx/sites-enabled/${domain}
	sudo rm -rf /opt/tomcat/${domain}
	sudo rm -rf /opt/tomcat/conf/Catalina/${domain}
	sudo rm -rf /var/www/${domain}
	sudo rm -rf /srv/${domain}
	"

	[[ $? -eq 0 ]] && echo 'site removed!'
}

build_site() {
	while [[ $# -gt 0 ]] ; do
	    arg=$1 ; shift
	    case $arg in
	        -d|--domain) domain=$1 ; shift;;
	        --domain=*) domain=${arg#*=};;
	        *) echo "Unknown argument: $arg" ; exit 1;;
	    esac
	done
	if [[ -z $domain ]] ; then
		cat <<-.
		Trigger a build and deploy for a site

		-d|--domain <domain> -- name of the site to build and deploy

		Examples:
		    $(basename $0) site build -d example.com
		    $(basename $0) site build --domain=example.com
		.
		die
	fi

	# ensure site exists
	list_sites | grep "^$site$" >/dev/null || die "It looks like $site does not exist. Aborting..."

	echo "Running post-receive hook for $site"

	ssh -t $user@$ip "
	cd /srv/$site/repo.git
	hooks/post-receive
	"
}

deploy_site() {
	while [[ $# -gt 0 ]] ; do
	    arg=$1 ; shift
	    case $arg in
	        -f|--filepath) war_filepath=$1 ; shift;;
	        --filepath=*) war_filepath=${arg#*=} ; war_filepath="${war_filepath/#\~/$HOME}";;
			-d|--domain) domain=$1 ; shift;;
			--domain=*) domain=${arg#*=};;
	        *) echo "Unknown argument: $arg" ; exit 1;;
	    esac
	done
	if [[ -z $domain ]] || [[ -z $war_filepath ]] ; then
		cat <<-.
		Deploy a pre-built war file.

		You should probably only do this if you really know what youre doing,
		for most use cases, git deployment is recommended. See also the 'build'
		subcommand.

		-d|--domain <domain>     -- name of the site to deploy
		-f|--filepath <filepath> -- path to the war file

		Example:
		    $(basename $0) site deploy -d example.com -f ~/example-project.war
		.
		die
	fi

	# ensure file exists and is a war (or at least has the extension)
	if [[ ! -f $war_filepath ]]; then
		echo 'It looks like that file does not exist!'
		exit 1
	fi
	if [[ "$war_filepath" != *.war ]] ; then
		echo 'It looks like that file is not a valid war file (it does not have the)' >&2
		die '".war" file extension. Aborting...'
	fi

	# ensure site exists
	list_sites | grep "^$domain$" >/dev/null || die "It looks like $site does not exist. Aborting..."

	scp "$war_filepath" $user@$ip:/opt/tomcat/${domain}/ROOT.war
}

show_info() {
	while [[ $# -gt 0 ]] ; do
	    arg=$1 ; shift
	    case $arg in
	        -d|--domain) domain=$1 ; shift;;
	        --domain=*) domain=${arg#*=};;
	        *) echo "Unknown argument: $arg" ; exit 1;;
	    esac
	done
	if [[ -z $domain ]] ; then
		cat <<-.
		Show information about a site that is setup on the server

		-d|--domain <domain> -- name of the site to show information about

		Example:
		    $(basename $0) site info -d example.com
		.
		die
	fi

	# ensure site exists
	list_sites | grep "^$domain$" >/dev/null || die "It looks like $site does not exist. Aborting..."

	cat <<-.
		Site: $domain

		uploads directory:     /var/www/$domain/uploads
		nginx config file:     /etc/nginx/domains-available/$domain
		deployment git remote: $user@$ip:/srv/$domain/repo.git

		To add the deployment remote for this domain, run:

		    git remote add production $user@$ip:/srv/$domain/repo.git

	.
}

show_help() {
	cat <<-help
	site -- command for managing sites setup on your server
	usage

	    $(basename $0) site <command> [options]

	where <command> is one of the following:

	    list -- list the sites setup on your server

	    create:java   -d <domain>
	    create:static -d <domain>
	    remove        -d <domain>
	    build         -d <domain>
	    enablessl     -d <domain>
	    info          -d <domain>
	    deploy        -d <domain> -f <warfile>

	help
}

command=$1
shift

case $command in
	list|ls)       list_sites;;
	create:java)   create_site $@;;
	create:static) create_static_site $@;;
	remove|rm)     remove_site $@;;
	build)	       build_site $@;;
	enablessl)     enable_ssl $@;;
	info)          show_info $@;;
	deploy)	       deploy_site $@;;
	*)             show_help;;
esac
