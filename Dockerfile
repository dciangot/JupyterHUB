## docker build -t gitlab-registry.cern.ch/swan/docker-images/dev-jupyter .
## docker push gitlab-registry.cern.ch/swan/docker-images/dev-jupyter

FROM jupyter/minimal-notebook:63d0df23b673


MAINTAINER Diogo Castro <diogo.castro@cern.ch>
MAINTAINER Piotr Mrowczynski <piotr.mrowczynski@cern.ch>

USER root

RUN apt-get update

# Install required apt packages for all the extensions
RUN apt-get update && apt-get -y install vim sudo git curl openjdk-8-jdk

RUN echo "jovyan ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# Install required python packages for all the extensions
# Force lab version 2, since we're targeting development to that version
RUN pip install \
        pyspark \
        jupyter_nbextensions_configurator \
        widgetsnbextension \
        itkwidgets \
        plotly \
        bs4 \
        kubernetes==9.0.0 \
        'jupyterlab>=2.0.0rc2'

# Use bash instead of dash
RUN rm /bin/sh && \
    ln -s /bin/bash /bin/sh

ARG URL_NBEXTENSIONS=https://gitlab.cern.ch/api/v4/projects/25624/jobs/artifacts/qa/download?job=release-daily
ARG SWAN_COMMON_BRANCH=qa

## Get latest - not necessarily tagged - version of the css files and compile them
RUN git clone -b $SWAN_COMMON_BRANCH https://gitlab.cern.ch/swan/common.git /tmp/custom && \
    cp -r /tmp/custom/images/* /opt/conda/lib/python3.7/site-packages/notebook/static/custom/

COPY ./custom.css /opt/conda/lib/python3.7/site-packages/notebook/static/custom/

# Install our extensions just like in prod (but also enable sparkconnector and hdfsbrowser)
RUN mkdir /tmp/jupyter_extensions && \
    cd /tmp/jupyter_extensions && \
    wget ${URL_NBEXTENSIONS} -O extensions.zip && \
    unzip extensions.zip && \
    # Install all SWAN extensions which are packaged as python modules
    # Ignore dependencies because they have already been installed or come from CVMFS
    ls -d ./SparkMonitor/ | xargs -n1 sh -c 'cd $0 ; pip install --no-deps .' && \
    ls -d ./SparkConnector/ | xargs -n1 sh -c 'cd $0 ; pip install --no-deps .' && \
    #ls -d ./SwanKernelEnv/ | xargs -n1 sh -c 'cd $0 ; pip install --no-deps .' && \
    # Automatically install all nbextensions from their python module (all extensions need to implement the api even if they return 0 nbextensions)
    ls -d ./SparkMonitor/ | xargs -n1 sh -c 'extension=$(basename $0) ; jupyter nbextension install --py --system ${extension,,} || exit 1' && \
    ls -d ./SparkConnector/ | xargs -n1 sh -c 'extension=$(basename $0) ; jupyter nbextension install --py --system ${extension,,} || exit 1' && \
    #ls -d ./SwanKernelEnv/ | xargs -n1 sh -c 'extension=$(basename $0) ; jupyter nbextension install --py --system ${extension,,} || exit 1' && \
    # Enable the server extensions
    server_extensions=('sparkmonitor' 'sparkconnector') && \
    for extension in ${server_extensions[@]}; do jupyter serverextension enable --py --system $extension || exit 1 ; done && \
    # Enable the nb extensions
    # Not all nbextensions are activated as some of them are activated on session startup or by the import in the templates
    nb_extensions=('sparkmonitor' 'sparkconnector') && \
    for extension in ${nb_extensions[@]}; do jupyter nbextension enable --py --system $extension || exit 1; done && \
    # Force nbextension_configurator systemwide to prevent users disabling it
    jupyter nbextensions_configurator enable --system && \
    # Clean
    rm -rf /tmp/jupyter_extensions


# Enable Kernel extensions
RUN mkdir -p /home/$NB_USER/.ipython/profile_default/ && \
    printf "c.InteractiveShellApp.extensions.append('sparkmonitor.kernelextension') \
\nc.InteractiveShellApp.extensions.append('sparkconnector.connector') \
" > /home/$NB_USER/.ipython/profile_default/ipython_kernel_config.py

# Set Jupyter configurations
RUN printf "import os \
\nc = get_config() \
\nc.NotebookApp.ip = '0.0.0.0' \
\nc.NotebookApp.port = 8888 \
\nc.NotebookApp.open_browser = False \
\nc.InteractiveShellApp.extensions.append('sparkmonitor.kernelextension') \
\nc.InteractiveShellApp.extensions.append('sparkconnector.kernelextension') \
\nif \"JUPYTER_TOKEN\" in os.environ: \
\n    c.NotebookApp.token = os.environ[\"JUPYTER_TOKEN\"] \
" > /home/$NB_USER/.jupyter/jupyter_notebook_config.py

# Adjust Permissions to be able to overwrite the files
RUN chmod g+w -R /usr/local/share/jupyter/nbextensions && \
    chown -R root:users /usr/local/share/jupyter/nbextensions && \
    chmod g+w -R /opt/conda/lib/python3.7/site-packages

# Add projects folder and fix permissions
RUN mkdir /home/$NB_USER/SWAN_projects && \
    fix-permissions /home/$NB_USER

#COPY ./dist  /usr/local/spark
RUN cd /usr/local/ && wget https://downloads.apache.org/spark/spark-3.0.0/spark-3.0.0-bin-hadoop3.2.tgz && \
        tar -xzvf spark-3.0.0-bin-hadoop3.2.tgz && \
        mv spark-3.0.0-bin-hadoop3.2 spark && \
        rm -f spark-3.0.0-bin-hadoop3.2.tgz

COPY ./minio_jars/* /usr/local/spark/jars/

COPY spark-defaults.conf /usr/local/spark/conf/spark-defaults.conf
RUN chown $NB_UID:$NB_UID /usr/local/spark/conf/spark-defaults.conf

RUN echo -e "#!/bin/bash \
\nsudo sed -ie 's/spark.driver.host master/spark.driver.host '$(hostname -i)'/' /usr/local/spark/conf/spark-defaults.conf\n$1" > /usr/bin/start.sh

RUN chmod +x /usr/bin/start.sh

RUN cat /opt/conda/lib/python3.7/site-packages/sparkconnector/configuration.py

COPY ./connector.py /opt/conda/lib/python3.7/site-packages/sparkconnector/configuration.py
COPY ./portallocator.py /opt/conda/lib/python3.7/site-packages/sparkconnector/portallocator.py

RUN apt-get install -y  fuse

COPY ./jupyterhub-singleuser /opt/conda/bin/jupyterhub-singleuser

RUN chmod +x /opt/conda/bin/jupyterhub-singleuser

USER $NB_UID

RUN pip install jupyterhub-kubespawner oauthenticator

WORKDIR /home/$NB_USER/SWAN_projects
RUN mkdir -p .init
COPY hub_config.py ./.init/jupyterhub_config.py
COPY ./sts-wire ./.init/sts-wire
COPY ./spawn.sh ./.init/spawn.sh
RUN sudo chown -R $NB_USER .init

RUN sudo chown -R $NB_USER  /usr/local/spark
ENV SPARK_HOME /usr/local/spark
ENV PYTHONPATH $SPARK_HOME/python:$SPARK_HOME/python/lib/py4j-0.10.7-src.zip:$PYTHONPATH
ENV SPARK_OPTS --driver-java-options=-Xms1024M --driver-java-options=-Xmx1024M --driver-java-options=-Dlog4j.logLevel=debug

COPY ./entrypoint.sh ./entrypoint.sh

RUN sudo chmod +x entrypoint.sh

COPY listener.jar /opt/conda/lib/python3.7/site-packages/sparkmonitor/listener.jar

ENTRYPOINT ["./entrypoint.sh"]
