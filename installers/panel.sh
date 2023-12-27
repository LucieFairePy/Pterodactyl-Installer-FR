#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Projet 'pterodactyl-installer'                                                    #
#                                                                                    #
# Droits d'auteur (C) 2018 - 2023, Vilhelm Prytz, <vilhelm@prytznet.se>             #
#                                                                                    #
#   Ce programme est un logiciel libre : vous pouvez le redistribuer ou le modifier  #
#   selon les termes de la Licence publique générale GNU telle que publiée par la    #
#   Free Software Foundation, soit la version 3 de la Licence, ou (selon votre        #
#   choix) toute version ultérieure.                                                 #
#                                                                                    #
#   Ce programme est distribué dans l'espoir qu'il sera utile, mais SANS AUCUNE      #
#   GARANTIE, même sans la garantie implicite de COMMERCIALISATION ou                 #
#   D'ADÉQUATION À UN USAGE PARTICULIER. Voir la Licence publique générale GNU        #
#   pour plus de détails.                                                            #
#                                                                                    #
#   Vous devez avoir reçu une copie de la Licence publique générale GNU               #
#   avec ce programme. Si ce n'est pas le cas, consultez <https://www.gnu.org/licenses/>. #
#                                                                                    #
# https://github.com/pterodactyl-installer/pterodactyl-installer/blob/master/LICENSE #
#                                                                                    #
# Ce script n'est pas associé au projet officiel Pterodactyl.                         #
# https://github.com/pterodactyl-installer/pterodactyl-installer                     #
#                                                                                    #
######################################################################################

# Vérifie si le script est chargé, le charge sinon échoue.
fn_exists() { declare -F "$1" >/dev/null; }
if ! fn_exists lib_loaded; then
  # shellcheck source=lib/lib.sh
  source /tmp/lib.sh || source <(curl -sSL "$GITHUB_BASE_URL/$GITHUB_SOURCE"/lib/lib.sh)
  ! fn_exists lib_loaded && echo "* ERREUR : Impossible de charger le script lib" && exit 1
fi

# ------------------ Variables ----------------- #

# Nom de domaine / IP
FQDN="${FQDN:-localhost}"

# Informations de connexion MySQL par défaut
MYSQL_DB="${MYSQL_DB:-panel}"
MYSQL_USER="${MYSQL_USER:-pterodactyl}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-$(gen_passwd 64)}"

# Environnement
timezone="${timezone:-Europe/Stockholm}"

# Supposer SSL, récupère une configuration différente si vrai
ASSUME_SSL="${ASSUME_SSL:-false}"
CONFIGURE_LETSENCRYPT="${CONFIGURE_LETSENCRYPT:-false}"

# Pare-feu
CONFIGURE_FIREWALL="${CONFIGURE_FIREWALL:-false}"

# Doit être attribué pour fonctionner, pas de valeurs par défaut
email="${email:-}"
user_email="${user_email:-}"
user_username="${user_username:-}"
user_firstname="${user_firstname:-}"
user_lastname="${user_lastname:-}"
user_password="${user_password:-}"

if [[ -z "${email}" ]]; then
  error "L'email est requis"
  exit 1
fi

if [[ -z "${user_email}" ]]; then
  error "L'email de l'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_username}" ]]; then
  error "Le nom d'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_firstname}" ]]; then
  error "Le prénom de l'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_lastname}" ]]; then
  error "Le nom de famille de l'utilisateur est requis"
  exit 1
fi

if [[ -z "${user_password}" ]]; then
  error "Le mot de passe de l'utilisateur est requis"
  exit 1
fi
# --------- Fonctions principales d'installation -------- #

install_composer() {
  output "Installation de Composer.."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
  success "Composer installé !"
}

ptdl_dl() {
  output "Téléchargement des fichiers du panneau Pterodactyl .. "
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl || exit

  curl -Lo panel.tar.gz "$PANEL_DL_URL"
  tar -xzvf panel.tar.gz
  chmod -R 755 storage/* bootstrap/cache/

  cp .env.example .env

  success "Fichiers du panneau Pterodactyl téléchargés !"
}

install_composer_deps() {
  output "Installation des dépendances de Composer.."
  [ "$OS" == "rocky" ] || [ "$OS" == "almalinux" ] && export PATH=/usr/local/bin:$PATH
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader
  success "Dépendances de Composer installées !"
}

# Configuration de l'environnement
configure() {
  output "Configuration de l'environnement.."

  local app_url="http://$FQDN"
  [ "$ASSUME_SSL" == true ] && app_url="https://$FQDN"
  [ "$CONFIGURE_LETSENCRYPT" == true ] && app_url="https://$FQDN"

  # Générer la clé de chiffrement
  php artisan key:generate --force

  # Remplir automatiquement environment:setup
  php artisan p:environment:setup \
    --author="$email" \
    --url="$app_url" \
    --timezone="$timezone" \
    --cache="redis" \
    --session="redis" \
    --queue="redis" \
    --redis-host="localhost" \
    --redis-pass="null" \
    --redis-port="6379" \
    --settings-ui=true

  # Remplir automatiquement environment:database avec les identifiants
  php artisan p:environment:database \
    --host="127.0.0.1" \
    --port="3306" \
    --database="$MYSQL_DB" \
    --username="$MYSQL_USER" \
    --password="$MYSQL_PASSWORD"

  # Configurer la base de données
  php artisan migrate --seed --force

  # Créer le compte utilisateur
  php artisan p:user:make \
    --email="$user_email" \
    --username="$user_username" \
    --name-first="$user_firstname" \
    --name-last="$user_lastname" \
    --password="$user_password" \
    --admin=1

  success "Environnement configuré !"
}

# Définir les permissions de dossier appropriées en fonction du système d'exploitation et du serveur web
set_folder_permissions() {
  # Si le système d'exploitation est Ubuntu ou Debian, nous faisons cela
  case "$OS" in
  debian | ubuntu)
    chown -R www-data:www-data ./*
    ;;
  rocky | almalinux)
    chown -R nginx:nginx ./*
    ;;
  esac
}

insert_cronjob() {
  output "Installation de la tâche cron.. "

  crontab -l | {
    cat
    output "* * * * php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1"
  } | crontab -

  success "Tâche cron installée !"
}

install_pteroq() {
  output "Installation du service pteroq.."

  curl -o /etc/systemd/system/pteroq.service "$GITHUB_URL"/configs/pteroq.service

  case "$OS" in
  debian | ubuntu)
    sed -i -e "s@<user>@www-data@g" /etc/systemd/system/pteroq.service
    ;;
  rocky | almalinux)
    sed -i -e "s@<user>@nginx@g" /etc/systemd/system/pteroq.service
    ;;
  esac

  systemctl enable pteroq.service
  systemctl start pteroq

  success "Service pteroq installé !"
}

# ------ Fonctions d'installation spécifiques à l'OS ------- #

enable_services() {
  case "$OS" in
  ubuntu | debian)
    systemctl enable redis-server
    systemctl start redis-server
    ;;
  rocky | almalinux)
    systemctl enable redis
    systemctl start redis
    ;;
  esac
  systemctl enable nginx
  systemctl enable mariadb
  systemctl start mariadb
}
selinux_allow() {
  setsebool -P httpd_can_network_connect 1 || true # Ces commandes peuvent échouer OK
  setsebool -P httpd_execmem 1 || true
  setsebool -P httpd_unified 1 || true
}

php_fpm_conf() {
  curl -o /etc/php-fpm.d/www-pterodactyl.conf "$GITHUB_URL"/configs/www-pterodactyl.conf

  systemctl enable php-fpm
  systemctl start php-fpm
}

ubuntu_dep() {
  # Installer les dépendances pour ajouter des dépôts
  install_packages "software-properties-common apt-transport-https ca-certificates gnupg"

  # Ajouter le dépôt d'Ubuntu universe
  add-apt-repository universe -y

  # Ajouter le PPA pour PHP (nous avons besoin de 8.1)
  LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
}

debian_dep() {
  # Installer les dépendances pour ajouter des dépôts
  install_packages "dirmngr ca-certificates apt-transport-https lsb-release"

  # Installer PHP 8.1 en utilisant le dépôt de sury
  curl -o /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
  echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/php.list
}

alma_rocky_dep() {
  # Outils SELinux
  install_packages "policycoreutils selinux-policy selinux-policy-targeted \
    setroubleshoot-server setools setools-console mcstrans"

  # Ajouter le dépôt remi (php8.1)
  install_packages "epel-release http://rpms.remirepo.net/enterprise/remi-release-$OS_VER_MAJOR.rpm"
  dnf module enable -y php:remi-8.1
}

dep_install() {
  output "Installation des dépendances pour $OS $OS_VER..."

  # Mettre à jour les dépôts avant l'installation
  update_repos

  [ "$CONFIGURE_FIREWALL" == true ] && install_firewall && firewall_ports

  case "$OS" in
  ubuntu | debian)
    [ "$OS" == "ubuntu" ] && ubuntu_dep
    [ "$OS" == "debian" ] && debian_dep

    update_repos

    # Installer les dépendances
    install_packages "php8.1 php8.1-{cli,common,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip} \
      mariadb-common mariadb-server mariadb-client \
      nginx \
      redis-server \
      zip unzip tar \
      git cron"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    ;;
  rocky | almalinux)
    alma_rocky_dep

    # Installer les dépendances
    install_packages "php php-{common,fpm,cli,json,mysqlnd,mcrypt,gd,mbstring,pdo,zip,bcmath,dom,opcache,posix} \
      mariadb mariadb-server \
      nginx \
      redis \
      zip unzip tar \
      git cronie"

    [ "$CONFIGURE_LETSENCRYPT" == true ] && install_packages "certbot python3-certbot-nginx"

    # Autoriser nginx
    selinux_allow

    # Créer la configuration pour php fpm
    php_fpm_conf
    ;;
  esac

  enable_services

  success "Dépendances installées !"
}

# --------------- Autres fonctions -------------- #

firewall_ports() {
  output "Ouverture des ports : 22 (SSH), 80 (HTTP) et 443 (HTTPS)"

  firewall_allow_ports "22 80 443"

  success "Ports du pare-feu ouverts !"
}
letsencrypt() {
  FAILED=false

  output "Configuration de Let's Encrypt..."

  # Obtenir le certificat
  certbot --nginx --redirect --no-eff-email --email "$email" -d "$FQDN" || FAILED=true

  # Vérifier si cela a réussi
  if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
    warning "Le processus d'obtention d'un certificat Let's Encrypt a échoué !"
    echo -n "* Toujours supposer SSL ? (y/N) : "
    read -r CONFIGURE_SSL

    if [[ "$CONFIGURE_SSL" =~ [Yy] ]]; then
      ASSUME_SSL=true
      CONFIGURE_LETSENCRYPT=false
      configure_nginx
    else
      ASSUME_SSL=false
      CONFIGURE_LETSENCRYPT=false
    fi
  else
    success "Le processus d'obtention d'un certificat Let's Encrypt a réussi !"
  fi
}

# ------ Fonctions de configuration du serveur Web ------- #

configure_nginx() {
  output "Configuration de nginx .."

  if [ "$ASSUME_SSL" == true ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    DL_FILE="nginx_ssl.conf"
  else
    DL_FILE="nginx.conf"
  fi

  case "$OS" in
  ubuntu | debian)
    PHP_SOCKET="/run/php/php8.1-fpm.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/sites-available"
    CONFIG_PATH_ENABL="/etc/nginx/sites-enabled"
    ;;
  rocky | almalinux)
    PHP_SOCKET="/var/run/php-fpm/pterodactyl.sock"
    CONFIG_PATH_AVAIL="/etc/nginx/conf.d"
    CONFIG_PATH_ENABL="$CONFIG_PATH_AVAIL"
    ;;
  esac

  rm -rf "$CONFIG_PATH_ENABL"/default

  curl -o "$CONFIG_PATH_AVAIL"/pterodactyl.conf "$GITHUB_URL"/configs/$DL_FILE

  sed -i -e "s@<domain>@${FQDN}@g" "$CONFIG_PATH_AVAIL"/pterodactyl.conf

  sed -i -e "s@<php_socket>@${PHP_SOCKET}@g" "$CONFIG_PATH_AVAIL"/pterodactyl.conf

  case "$OS" in
  ubuntu | debian)
    ln -sf "$CONFIG_PATH_AVAIL"/pterodactyl.conf "$CONFIG_PATH_ENABL"/pterodactyl.conf
    ;;
  esac

  if [ "$ASSUME_SSL" == false ] && [ "$CONFIGURE_LETSENCRYPT" == false ]; then
    systemctl restart nginx
  fi

  success "Nginx configuré !"
}

# --------------- Fonctions principales --------------- #

perform_install() {
  output "Démarrage de l'installation.. cela peut prendre un certain temps !"
  dep_install
  install_composer
  ptdl_dl
  install_composer_deps
  create_db_user "$MYSQL_USER" "$MYSQL_PASSWORD"
  create_db "$MYSQL_DB" "$MYSQL_USER"
  configure
  set_folder_permissions
  insert_cronjob
  install_pteroq
  configure_nginx
  [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt

  return 0
}

# ------------------- Installation ------------------ #

perform_install
