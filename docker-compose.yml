services:
  nextcloud:
    image: nextcloud:latest
    restart: unless-stopped
    ports:
      - "${NEXTCLOUD_PORT}:80"
    environment:
      - NEXTCLOUD_ADMIN_USER=${NEXTCLOUD_ADMIN_USER}
      - NEXTCLOUD_ADMIN_PASSWORD=${NEXTCLOUD_ADMIN_PASSWORD}
      - NEXTCLOUD_TRUSTED_DOMAINS=${NEXTCLOUD_TRUSTED_DOMAINS}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
      - MYSQL_HOST=db
    volumes:
      - nextcloud_html:/var/www/html
      - ${NEXTCLOUD_DATA_DIR}:/var/www/html/data
    depends_on:
      - db

  db:
    image: mariadb:latest
    restart: unless-stopped
    environment:
      - MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
      - MYSQL_PASSWORD=${MYSQL_PASSWORD}
      - MYSQL_DATABASE=${MYSQL_DATABASE}
      - MYSQL_USER=${MYSQL_USER}
    volumes:
      - db_data:/var/lib/mysql

volumes:
  nextcloud_html:
  db_data:
