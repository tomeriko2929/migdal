# Use the NGINX image from Docker Hub
FROM nginx:alpine

# Copy the index.html file to the NGINX html directory
COPY index.html /usr/share/nginx/html/index.html

