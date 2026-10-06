# Version VOLONTAIREMENT cassee de publications, pour le scenario 8
# (version defectueuse puis retour arriere). Le programme s'arrete des le
# demarrage avec une erreur.
#
#   docker build -t registry.local:5000/nebula-publications:v3-casse .
#   docker push registry.local:5000/nebula-publications:v3-casse
FROM registry.local:5000/nebula-publications:v2
USER root
RUN printf 'console.error("[publications] v3-casse : erreur fatale au demarrage (version volontairement cassee)");\nprocess.exit(1);\n' > /app/src/index.js
USER node
