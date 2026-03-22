FROM nginx:1.28-alpine
COPY index-blue.html /usr/share/nginx/html/index-blue.html
COPY index-green.html /usr/share/nginx/html/index-green.html
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["blue"]
