/**
 * States and Countries cannot be created by deploying Address Settings.
 * This tool submits all states into the Setup screen using page scraping.
 *
 * Resolves:
 * https://success.salesforce.com/ideaView?id=08730000000l6DGAAY
 * https://salesforce.stackexchange.com/questions/20755/how-to-mass-populate-state-country-picklist-values
 * https://salesforce.stackexchange.com/questions/78377/how-to-write-address-settings-in-order-to-implement-country-picklists-via-metada
 */
public inherited sharing class StateCodes implements Database.Batchable<String>, Database.AllowsCallouts, Database.Stateful, HttpCalloutMock
{
    public String stateCodes {get; set;}
    ApexPages.StandardController controller;
    // Track handled exceptions across batch executions
    private List<String> handledExceptions = new List<String>();


    public StateCodes(ApexPages.StandardController controller)
    {
        this.controller = controller;
        this.stateCodes = Json.serializePretty(scope2state);
    }
    
    public PageReference action()
    {
        if (this.controller.getId() != null)
        {
            this.controller.reset();
            return null;
        }
        else
        {
            List<AsyncApexJob> jobs = [SELECT Id FROM AsyncApexJob WHERE CompletedDate = null AND ApexClass.Name = 'StateCodes'];
            if (!jobs.isEmpty()) return new PageReference('/apex/StateCodes?id=' + jobs[0].Id);
            else return null;
        }
    }
    
    public PageReference startBatch()
    {
        try
        {
            Object scope2state = Json.deserialize(stateCodes, Map<String,String>.class);
            Id jobId = run((Map<String,String>)scope2state);
            
            PageReference redirect = new PageReference('/apex/StateCodes');
            redirect.getParameters().put('id', jobId);
            redirect.setRedirect(true);
            return redirect;
        }
        catch (Exception e)
        {
            ApexPages.addMessages(e);
            return null;
        }
    }
    
    public void abortBatch()
    {
        try
        {
            System.AbortJob(controller.getId());
            this.controller.reset();
        }
        catch (Exception e)
        {
            ApexPages.addMessages(e);
        }
    }
    
    /**
     * Runs batch to create 4,936 default ISO states
     */
    static public Id run(Map<String,String> scope2state)
    {
        if (isRunning()) throw new AsyncException('Batch already running');
        StateCodes batch = new StateCodes();
        if (scope2state != null) batch.scope2state = scope2state;
        return Database.executeBatch(batch, 1);
    }

    /**
     * Avoid simultaneous jobs
     */
    static Boolean isRunning()
    {
        return ![
            SELECT Id
            FROM AsyncApexJob
            WHERE CompletedDate = null
            AND ApexClass.Name = 'StateCodes'
        ].isEmpty();
    }
    
    /**
     * Private constructor to avoid
     * running with wrong scope size
     */
    @TestVisible StateCodes()
    {
        // use run() method
    }

    /**
     * Iterate all codes so we get 1
     * execution context for each state
     */
    public Iterable<String> start(Database.BatchableContext context)
    {
        // check remote site setting to base url
        HttpRequest request = new HttpRequest();
        request.setMethod('GET');
        request.setEndpoint(Url.getOrgDomainUrl().toExternalForm());
        if (!Test.isRunningTest()) new Http().send(request);
        
        return new List<String>(scope2state.keySet());
    }

    /**
     * Attempt to create each state inside its country,
     * failures are written to documents in user folder
     */
    public void execute(Database.BatchableContext context, List<String> scopes)
    {
        List<Document> documents = new List<Document>();
        
        for (String scope : scopes)
        {
            String countryCode = scope.substringBefore('-');
            String stateCode = scope.substringAfter('-');
            String stateName = scope2state.get(scope);
            String stateLabel = stateName;
            if(stateLabel.contains(stateCode)){
                stateLabel = 'NULL';
            }
            
            
            try
            {
                newState(countryCode, stateCode, stateName, stateLabel);
            }
            catch (HandledException e)
            {
                // Collect handled exception details
                handledExceptions.add('Country: ' + countryCode + ', State: ' + stateCode + ' - ' + e.getMessage());
                continue;
            }
            catch (UnsupportedOperationException e)
            {
                // save in document
                documents.add(new Document(
                    Name = scope + '.txt',
                    FolderId = UserInfo.getUserId(),
                    Body = Blob.valueOf(e.getMessage()
                )));
            }
            
            insert documents;
        }
    }

    /**
     * Email to notify the
     * batch has finished
     */
    public void finish(Database.BatchableContext context)
    {
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setSaveAsActivity(false);
        email.setTargetObjectId(UserInfo.getUserId());
        email.setSubject('State Codes - batch completed');

        String emailBody = '';
        if (!handledExceptions.isEmpty()) {
            emailBody += 'Handled Exceptions encountered:\n';
            for (String e : handledExceptions) {
                emailBody += e + '\n';
            }
        } else {
            emailBody += 'No Handled Exceptions encountered.\n\n';
        }

        emailBody += 'See results in Documents and Apex Jobs page.';
        email.setPlainTextBody(emailBody);
        Messaging.sendEmail(new List<Messaging.Email>{email});
    }
    
    /**
     * Attempting two callouts helps mitigate 'Read timed out' exceptions
     * (this class makes only idempotent requests to configure new states)
     */
    static HttpResponse sendTwice(HttpRequest request)
    {
        request.setTimeout(60 * 1000);
        try
        {
            // attempt 1
            return new Http().send(request);
        }
        catch (CalloutException e)
        {
            // attempt 2
            if (Test.isRunningTest()) throw e; else return new Http().send(request);
        }
    }

    /**
     * Grab the HTML for the 'Configure New State' form
     * and post back to the server with name/code values
     */
    public void newState(String countryCode, String stateCode, String stateName, String stateLabel)
    {
        String orgUrl = Url.getOrgDomainUrl().toExternalForm();
        
        // extract form page
        HttpRequest getRequest = new HttpRequest();
        getRequest.setMethod('GET');
        getRequest.setEndpoint(orgUrl + '/i18n/ConfigureNewState.apexp?countryIso=' + countryCode);
        getRequest.setHeader('Cookie', 'sid=' + UserInfo.getSessionId());
        
        if (Test.isRunningTest()) Test.setMock(HttpCalloutMock.class, this);
        HttpResponse getResponse = sendTwice(getRequest);
        
        // extract viewstate params (country code is stored inside here)
        String viewState = getResponse.getBody().substringBetween('com.salesforce.visualforce.ViewState" value="', '"');
        String viewStateMac = getResponse.getBody().substringBetween('com.salesforce.visualforce.ViewStateMAC" value="', '"');
        String viewStateCsrf = getResponse.getBody().substringBetween('com.salesforce.visualforce.ViewStateCSRF" value="', '"');
        String viewStateVersion = getResponse.getBody().substringBetween('com.salesforce.visualforce.ViewStateVersion" value="', '"');
        
        // prepare post data
        PageReference postdata = new PageReference('');
        Map<String,String> parameters = postdata.getParameters();
        
        // add new state form fields
        parameters.put('configurenew:j_id1', 'configurenew:j_id1');
        parameters.put('configurenew:j_id1:blockNew:j_id43:addButton', 'Add');
        parameters.put('configurenew:j_id1:blockNew:j_id9:nameSectionItem:editName', stateLabel);
        parameters.put('configurenew:j_id1:blockNew:j_id9:codeSectionItem:editIsoCode', stateCode);
        parameters.put('configurenew:j_id1:blockNew:j_id9:intValSectionItem:editIntVal', stateName);
        parameters.put('configurenew:j_id1:blockNew:j_id9:activeSectionItem:editActive', 'true');
        
        // add viewstate params
        parameters.put('com.salesforce.visualforce.ViewState', viewState);
        parameters.put('com.salesforce.visualforce.ViewStateVersion', viewStateVersion);
        parameters.put('com.salesforce.visualforce.ViewStateMAC', viewStateMac);
        parameters.put('com.salesforce.visualforce.ViewStateCSRF', viewStateCsrf);
        
        // submit form
        HttpRequest postRequest = new HttpRequest();
        postRequest.setMethod('POST');
        postRequest.setBody(postdata.getUrl().substringAfter('?'));
        postRequest.setEndpoint(orgUrl + '/i18n/ConfigureNewState.apexp');
        postRequest.setHeader('Cookie', 'sid=' + UserInfo.getSessionId());
        postRequest.setHeader('Content-Type', 'application/x-www-form-urlencoded');

        if (Test.isRunningTest()) Test.setMock(HttpCalloutMock.class, this);
        HttpResponse postResponse = sendTwice(postRequest);
        
        if (postResponse.getBody().contains('<h4>Errors</h4>'))
        {
            String message = postResponse.getBody().substringBetween('<li style="padding-top:5px">', '</li>').trim();
            throw new HandledException(message);
        }
        
        if (postResponse.getBody().contains('<h4>Error:</h4>'))
        {
            String message = postResponse.getBody().substringBetween('<h4>Error:</h4></span>', '<').trim();
            throw new HandledException(message);
        }
        
        if (postResponse.getBody().contains('You are missing information'))
        {
            String message = 'Country does not exist: ' + countryCode;
            throw new HandledException(message);
        }
        
        if (!postResponse.getBody().contains('success=true'))
        {
            String message = 'Cannot find success redirect: ' + postResponse.getBody();
            throw new UnsupportedOperationException(message);
        }
    }
    
    public HttpResponse respond(HttpRequest request)
    {
        HttpResponse response = new HttpResponse();
        if (request.getMethod() == 'GET') response.setBody('<html></html>');
        if (request.getMethod() == 'POST') response.setBody('<a href="/?success=true">OK</a>');
        return response;
    }

    /**
     * All ISO assigned states in the format:
     * {CountryCode}-{StateCode} = {StateName}
     */
    Map<String,String> scope2state = new Map<String,String>{
        'TR-07' => 'Antalya',
        'FR-2A' => 'Corse-du-Sud',
        'FR-78' => 'Yvelines',
        'RS-20' => 'Nišavski okrug',
        'KR-11' => 'Seoul',
        'PL-02' => 'Kujawsko-pomorskie',
        'PT-50' => 'Porto',
        'AT-K' => 'Kärnten',
        'DE-10' => 'Saarland',
        'BE-02' => 'Antwerpen',
        'MY-PER' => 'Perak',
        'SE-011' => 'Västra GÖtalands län',
        'FR-45' => 'Loiret',
        'BE-04' => 'Oost-Vlaanderen',
        'RS-13' => 'Pomoravski okrug',
        'DE-16' => 'Thüringen',
        'PL-14' => 'Mazowieckie',
        'NL-09' => 'Noord-Holland',
        'SI-48' => 'Skuodas',
        'CO-05' => 'Antioquia',
        'PT-70' => 'Faro',
        'FR-30' => 'Gard',
        'IL-06' => 'Tel Aviv',
        'DK-004' => 'Region Midtjyllland',
        'MY-JOH' => 'Johor',
        'GR-16' => 'Dytikí Elláda',
        'VE-DF' => 'Distrito Capital',
        'AE-AZ' => 'Abu Dhabi',
        'NO-12' => 'Vestland',
        'RO-20' => 'Covasna',
        'NZ-WLG' => 'Greater Wellington',
        'FR-86' => 'Vienne',
        'BG-08' => 'Dobrich',
        'ID-17' => 'Nusa Tenggara Timur',
        'AT-B' => 'Burgenland',
        'PL-09' => 'Podkarpackie',
        'KZ-12' => 'Qaraghandy oblysy',
        'US-MH' => 'Marshall Islands',
        'FR-04' => 'Alpes-de-Haute-Provence',
        'FR-14' => 'Calvados',
        'UA-RIV' => 'Rivnenska oblast',
        'PE-06' => 'Cajamarca',
        'BE-09' => 'Namur',
        'PL-45' => 'Łódzkie',
        'ES-22' => 'Huesca',
        'PL-24' => 'Śląskie',
        'RO-13' => 'Constanța',
        'GR-41' => 'Nótio Aigaío',
        'FR-56' => 'Morbihan',
        'GR-05' => 'Thessalía',
        'FR-02' => 'Aisne',
        'KR-13' => 'Jeju-teukbyeoljachido',
        'AT-ST' => 'Steiermark',
        'DE-06' => 'Hessen',
        'NL-02' => 'Gelderland',
        'AE-RK' => 'Ras Al Khaimah',
        'CH-FR' => 'Fribourg',
        'DE-05' => 'Nordrhein-Westfalen',
        'NO-01' => 'Viken',
        'FR-92' => 'Hauts-de-Seine',
        'FR-44' => 'Loire-Atlantique',
        'TR-34' => 'İstanbul',
        'FR-33' => 'Gironde',
        'MY-KUL' => 'Wilayah Persekutuan Kuala Lumpur',
        'PE-11' => 'Ica',
        'HR-08' => 'Primorsko-goranska županija',
        'CN-020' => 'Guangdong Sheng',
        'FR-91' => 'Essonne',
        'CO-13' => 'Cundinamarca',
        'SI-38' => 'Raseiniai',
        'PT-31' => 'Açores',
        'KZ-00' => 'Astana',
        'CH-SG' => 'Sankt Gallen',
        'FI-002' => 'Etelä-Karjala',
        'US-VI' => 'Virgin Islands, U.S.',
        'ES-38' => 'Santa Cruz de Tenerife',
        'CH-SZ' => 'Schwyz',
        'FR-73' => 'Savoie',
        'SK-01' => 'Bratislavský kraj',
        'PL-01' => 'Dolnośląskie',
        'ES-46' => 'Valencia',
        'RO-10' => 'Buzău',
        'MY-KED' => 'Kedah',
        'DE-13' => 'Mecklenburg-Vorpommern',
        'HU-32' => 'Tolna',
        'HR-03' => 'Sisačko-moslavačka županija',
        'RO-06' => 'Bihor',
        'MX-MEX' => 'México',
        'HU-06' => 'Csongrád-Csanád',
        'FR-01' => 'Ain',
        'RO-29' => 'Sălaj',
        'DK-008' => 'Region Syddanmark',
        'NO-02' => 'Innlandet',
        'RO-05' => 'Bacău',
        'DK-006' => 'Region Sjælland',
        'RU-50' => 'Moskovskaya oblast',
        'ES-03' => 'Alicante',
        'NO-14' => 'Nordland',
        'CO-11' => 'Bogotá D.C.',
        'GR-20' => 'Dytikí Makedonía',
        'US-PR' => 'Puerto Rico',
        'PL-33' => 'Lubuskie',
        'NL-12' => 'Fryslân',
        'PL-23' => 'Świętokrzyskie',
        'VE-BOL' => 'Bolívar',
        'FR-974' => 'La Réunion',
        'RS-10' => 'Podunavski okrug',
        'AT-T' => 'Tirol',
        'DE-14' => 'Sachsen',
        'PL-16' => 'Opolskie',
        'KR-12' => 'Gwangju',
        'SI-47' => 'Širvintos',
        'DE-04' => 'Bremen',
        'IN-25' => 'Dādra and Nagar Haveli and Damān and Diu',
        'RO-12' => 'Călărași',
        'FR-67' => 'Bas-Rhin',
        'UA-CHG' => 'Chernihivska oblast',
        'GR-04' => 'Ípeiros',
        'PE-21' => 'San Martín',
        'GR-14' => 'Anatolikí Makedonía kai Thráki',
        'DK-001' => 'København',
        'FR-05' => 'Hautes-Alpes',
        'AE-SH' => 'Sharjah',
        'NL-05' => 'Utrecht',
        'GR-02' => 'Kentrikí Makedonía',
        'FR-32' => 'Gers',
        'RO-01' => 'Alba',
        'NL-06' => 'Limburg',
        'FR-06' => 'Alpes-Maritimes',
        'RS-1' => 'Severnobački okrug',
        'HU-01' => 'Bács-Kiskun',
        'DE-02' => 'Hamburg',
        'GB-IW' => 'Isle of Wight',
        'CH-NW' => 'Nidwalden',
        'NL-10' => 'Zuid-Holland',
        'VE-ANZ' => 'Anzoátegui',
        'BE-06' => 'Liège',
        'ID-09' => 'Jawa Barat',
        'PL-32' => 'Zachodniopomorskie',
        'ES-15' => 'A Coruña',
        'BE-05' => 'Limburg',
        'PL-17' => 'Podlaskie',
        'NO-11' => 'Rogaland',
        'VE-AMA' => 'Amazonas',
        'PL-41' => 'Wielkopolskie',
        'CH-VS' => 'Valais',
        'FR-43' => 'Haute-Loire',
        'SE-001' => 'Stockholms län',
        'GR-26' => 'Pelopónnisos',
        'IL-02' => 'Central',
        'GR-09' => 'Ionía Nísia',
        'FR-77' => 'Seine-et-Marne',
        'CL-07' => 'Maule',
        'DE-09' => 'Bayern',
        'RO-33' => 'Timiș',
        'RO-35' => 'Prahova',
        'NZ-WAI' => 'Waikato',
        'GR-01' => 'Attikí',
        'CO-23' => 'Risaralda',
        'FR-60' => 'Oise',
        'DE-01' => 'Schleswig-Holstein',
        'RO-18' => 'Gorj',
        'KZ-06' => 'Almaty oblysy',
        'RO-02' => 'Arad',
        'FR-57' => 'Moselle',
        'FR-13' => 'Bouches-du-Rhône',
        'AE-DU' => 'Dubai',
        'FR-85' => 'Vendée',
        'RO-14' => 'Dolj',
        'SE-019' => 'Västernorrlands län',
        'FR-66' => 'Pyrénées-Orientales',
        'PE-01' => 'Amazonas',
        'FR-75' => 'Paris',
        'ID-01' => 'Aceh',
        'ES-07' => 'Illes Balears',
        'CH-AG' => 'Aargau',
        'TR-48' => 'Muğla',
        'SE-012' => 'Gävleborgs län',
        'AR-03' => 'Corrientes',
        'DK-009' => 'Nordjylland',
        'NO-16' => 'Trøndelag',
        'RS-21' => 'Toplički okrug',
        'IL-01' => 'Northern',
        'RO-26' => 'Sibiu',
        'RO-09' => 'Brașov',
        'HU-26' => 'Vas',
        'RS-6' => 'Južnobački okrug',
        'RS-18' => 'Raški okrug',
        'PT-34' => 'Viseu',
        'HK-HK' => 'Hong Kong SAR',
        'NL-11' => 'Zeeland',
        'FR-11' => 'Aude',
        'KZ-10' => 'Abay oblysy',
        'RS-4' => 'Južnobanatski okrug',
        'MY-SEL' => 'Selangor',
        'CH-TG' => 'Thurgau',
        'HU-31' => 'Szabolcs-Szatmár-Bereg',
        'ES-13' => 'Ciudad Real',
        'SE-014' => 'Västmanlands län',
        'SI-60' => 'Valletta',
        'CH-SO' => 'Solothurn',
        'SE-002' => 'Uppsala län',
        'TW-TWN' => 'Taiwan Sheng',
        'ES-20' => 'Gipuzkoa',
        'PT-10' => 'Leiria',
        'DE-03' => 'Niedersachsen',
        'RU-66' => 'Sverdlovskaya oblast',
        'UA-VOL' => 'Volynska oblast',
        'SI-13' => 'Cerknica',
        'TR-78' => 'Karabük',
        'CH-BS' => 'Basel-Stadt',
        'DJ-DJ' => 'Djibouti',
        'CN-010' => 'Beijing Shi',
        'PL-25' => 'Warmińsko-mazurskie',
        'PL-07' => 'Małopolskie',
        'CH-BE' => 'Berne',
        'ZA-WC' => 'Western Cape',
        'RS-22' => 'Pirotski okrug',
        'RU-65' => 'Sakhalinskaya oblast',
        'BG-06' => 'Vratsa',
        'HR-11' => 'Požeško-slavonska županija',
        'JP-13' => 'Tokyo',
        'NO-15' => 'Møre og Romsdal',
        'IL-03' => 'Jerusalem',
        'AR-01' => 'Buenos Aires',
        'RO-IF' => 'Ilfov',
        'NZ-AKL' => 'Auckland',
        'DE-08' => 'Baden-Württemberg',
        'FR-95' => 'Val-d\'Oise',
        'HU-03' => 'Borsod-Abaúj-Zemplén',
        'TH-17' => 'Sing Buri',
        'NO-07' => 'Vestfold og Telemark',
        'AR-00' => 'Ciudad Autónoma de Buenos Aires',
        'HR-17' => 'Splitsko-dalmatinska županija',
        'AR-09' => 'San Juan',
        'SI-06' => 'Bovec',
        'HR-05' => 'Varaždinska županija',
        'KZ-07' => 'Batys Qazaqstan oblysy',
        'GR-22' => 'Stereá Elláda',
        'TR-33' => 'Mersin',
        'FR-34' => 'Hérault',
        'RO-37' => 'Teleorman',
        'ES-29' => 'Málaga',
        'TW-FJN' => 'Fujian Sheng',
        'FR-94' => 'Val-de-Marne',
        'HR-16' => 'Vukovarsko-srijemska županija',
        'GR-48' => 'Vóreio Aigaío',
        'CL-13' => 'Región Metropolitana de Santiago',
        'FR-63' => 'Puy-de-Dôme',
        'IN-13' => 'Jammu and Kashmīr',
        'SI-16' => 'Črna na Koroškem',
        'CH-GR' => 'Grischun',
        'TH-10' => 'Bangkok',
        'ES-16' => 'Cuenca',
        'FR-71' => 'Saône-et-Loire',
        'TR-01' => 'Adana',
        'RU-77' => 'Moskva',
        'BE-03' => 'Hainaut',
        'AT-S' => 'Salzburg',
        'TR-06' => 'Ankara',
        'JP-12' => 'Chiba',
        'BG-02' => 'Burgas',
        'LU-LU' => 'Lëtzebuerg',
        'PL-03' => 'Lubelskie',
        'ES-28' => 'Madrid',
        'RU-23' => 'Krasnodarskiy kray',
        'RU-35' => 'Kirovskaya oblast',
        'CN-120' => 'Tianjin Shi',
        'ES-23' => 'Jaén',
        'ZA-GP' => 'Gauteng',
        'FR-2B' => 'Haute-Corse',
        'ES-35' => 'Las Palmas',
        'ES-33' => 'Asturias',
        'TR-41' => 'Kocaeli',
        'CN-100' => 'Shanghai Shi',
        'TR-05' => 'Amasya',
        'CO-19' => 'Nariño',
        'BZ-BZ' => 'Belize',
        'SI-33' => 'Šalovci',
        'TW-TPE' => 'Taipei',
        'SI-23' => 'Domžale',
        'CH-LU' => 'Luzern',
        'NL-08' => 'Overijssel',
        'FR-68' => 'Haut-Rhin',
        'JP-01' => 'Hokkaido',
        'UA-KIE' => 'Kyiv',
        'FR-38' => 'Isère',
        'CZ-08' => 'Moravskoslezský kraj',
        'TR-16' => 'Bursa',
        'CH-ZG' => 'Zug',
        'RO-34' => 'Vâlcea',
        'HR-12' => 'Brodsko-posavska županija',
        'CH-ZH' => 'Zürich',
        'CH-GE' => 'Genève',
        'FI-003' => 'Etelä-Pohjanmaa',
        'RU-01' => 'Adygeya, Respublika',
        'ZA-EC' => 'Eastern Cape',
        'BE-08' => 'Luxembourg',
        'ES-01' => 'Álava',
        'SI-01' => 'Ajdovščina',
        'AE-AJ' => '‘Ajmān',
        'DE-07' => 'Rheinland-Pfalz',
        'FR-42' => 'Loire',
        'AT-W' => 'Wien',
        'FR-03' => 'Allier',
        'NL-03' => 'Noord-Brabant',
        'HR-01' => 'Zagrebačka županija',
        'JP-28' => 'Hyogo',
        'CH-UR' => 'Uri',
        'AT-V' => 'Vorarlberg',
        'KZ-08' => 'Soltüstik Qazaqstan oblysy',
        'PT-12' => 'Portalegre',
        'CL-01' => 'Tarapacá',
        'DE-15' => 'Sachsen-Anhalt',
        'ES-30' => 'Murcia',
        'CO-47' => 'Norte de Santander',
        'BG-01' => 'Blagoevgrad',
        'FR-81' => 'Tarn',
        'SE-021' => 'SÖdermanlands län',
        'ZA-FS' => 'Free State',
        'ES-45' => 'Toledo',
        'RO-25' => 'Suceava',
        'ES-09' => 'Burgos',
        'VE-MIR' => 'Miranda',
        'NO-03' => 'Oslo',
        'ES-04' => 'Almería',
        'ES-14' => 'Córdoba',
        'US-MP' => 'Northern Mariana Islands',
        'HR-21' => 'Grad Zagreb',
        'HR-02' => 'Krapinsko-zagorska županija',
        'TW-KSH' => 'Kaohsiung',
        'FI-001' => 'Ahvenanmaan maakunta',
        'UA-CHV' => 'Chernivetska oblast',
        'FR-93' => 'Seine-Saint-Denis',
        'RO-19' => 'Iași',
        'FR-69' => 'Rhône',
        'HR-04' => 'Karlovačka županija',
        'FR-22' => 'Côtes-d\'Armor',
        'FR-31' => 'Haute-Garonne',
        'ES-18' => 'Granada',
        'PK-PK' => 'PK',
        'GB-SW' => 'SW',
        'ZM-ZM' => 'ZM',
        'GB-ER' => 'ER',
        'GT-GT' => 'GT',
        'GB-SK' => 'SK',
        'GB-BL' => 'BL',
        'BS-BS' => 'BS',
        'GB-BE' => 'BE',
        'EE-EE' => 'EE',
        'SY-SY' => 'SY',
        'LI-LI' => 'LI',
        'BD-BD' => 'BD',
        'GF-GF' => 'GF',
        'TG-TG' => 'TG',
        'QA-QA' => 'QA',
        'CI-CI' => 'CI',
        'AG-AG' => 'AG',
        'GB-LS' => 'LS',
        'MG-MG' => 'MG',
        'RW-RW' => 'RW',
        'GH-GH' => 'GH',
        'ST-ST' => 'ST',
        'GB-MO' => 'MO',
        'GB-WI' => 'WI',
        'GB-OX' => 'OX',
        'KE-KE' => 'KE',
        'ER-ER' => 'ER',
        'FR-99' => '99',
        'GB-BR' => 'BR',
        'KY-KY' => 'KY',
        'YE-YE' => 'YE',
        'UZ-UZ' => 'UZ',
        'PY-PY' => 'PY',
        'MW-MW' => 'MW',
        'MD-MD' => 'MD',
        'MU-MU' => 'MU',
        'GB-BM' => 'BM',
        'CK-CK' => 'CK',
        'IM-IM' => 'IM',
        'MN-MN' => 'MN',
        'GB-YN' => 'YN',
        'SM-SM' => 'SM',
        'TN-TN' => 'TN',
        'GB-LC' => 'LC',
        'LK-LK' => 'LK',
        'GB-WA' => 'WA',
        'JO-JO' => 'JO',
        'GM-GM' => 'GM',
        'SD-SD' => 'SD',
        'ME-ME' => 'ME',
        'GB-NC' => 'NC',
        'KW-KW' => 'KW',
        'GB-CL' => 'CL',
        'HK-KLN' => 'KLN',
        'TJ-TJ' => 'TJ',
        'DO-DO' => 'DO',
        'NA-NA' => 'NA',
        'GB-WM' => 'WM',
        'GG-GG' => 'GG',
        'LB-LB' => 'LB',
        'IT-07' => '07',
        'GI-GI' => 'GI',
        'KH-KH' => 'KH',
        'SL-SL' => 'SL',
        'GB-NT' => 'NT',
        'GB-SC' => 'SC',
        'HT-HT' => 'HT',
        'GB-MK' => 'MK',
        'UG-UG' => 'UG',
        'BH-BH' => 'BH',
        'GB-GY' => 'GY',
        'EC-EC' => 'EC',
        'NE-NE' => 'NE',
        'IQ-IQ' => 'IQ',
        'GQ-GQ' => 'GQ',
        'GB-NK' => 'NK',
        'GB-NI' => 'NI',
        'MR-MR' => 'MR',
        'BO-BO' => 'BO',
        'LR-LR' => 'LR',
        'PA-PA' => 'PA',
        'MT-MT' => 'MT',
        'GN-GN' => 'GN',
        'GB-SU' => 'SU',
        'JE-JE' => 'JE',
        'CM-CM' => 'CM',
        'MM-MM' => 'MM',
        'GA-GA' => 'GA',
        'LY-LY' => 'LY',
        'GB-PB' => 'PB',
        'PT-32' => '32',
        'GB-HA' => 'HA',
        'GB-BK' => 'BK',
        'SA-SA' => 'SA',
        'GB-CA' => 'CA',
        'BF-BF' => 'BF',
        'NP-NP' => 'NP',
        'OM-OM' => 'OM',
        'SN-SN' => 'SN',
        'ET-ET' => 'ET',
        'VA-VA' => 'VA',
        'GB-YS' => 'YS',
        'GB-FM' => 'FM',
        'AL-AL' => 'AL',
        'GE-12' => '12',
        'NO-19' => '19',
        'MV-MV' => 'MV',
        'GB-GL' => 'GL',
        'VG-VG' => 'VG',
        'RS-YU' => 'YU',
        'GB-LE' => 'LE',
        'UY-UY' => 'UY',
        'VC-VC' => 'VC',
        'GB-WO' => 'WO',
        'GB-GW' => 'GW',
        'IS-IS' => 'IS',
        'MK-MK' => 'MK',
        'GB-YW' => 'YW',
        'KN-KN' => 'KN',
        'GB-AM' => 'AM',
        'ZW-ZW' => 'ZW',
        'GB-NH' => 'NH',
        'GY-GY' => 'GY',
        'SC-SC' => 'SC',
        'CV-CV' => 'CV',
        'CD-CD' => 'CD',
        'GB-WL' => 'WL',
        'BM-BM' => 'BM',
        'VN-VN' => 'VN',
        'GB-DO' => 'DO',
        'EG-EG' => 'EG',
        'JM-JM' => 'JM',
        'LV-LV' => 'LV',
        'GB-HT' => 'HT',
        'GB-SP' => 'SP',
        'GB-SL' => 'SL',
        'ID-ID' => 'ID',
        'BJ-BJ' => 'BJ',
        'GB-DU' => 'DU',
        'HK-NT' => 'NT',
        'GB-WD' => 'WD',
        'HN-HN' => 'HN',
        'GB-LA' => 'LA',
        'GB-CH' => 'CH',
        'XK-XK' => 'XK',
        'GB-DB' => 'DB',
        'MZ-MZ' => 'MZ',
        'GB-PY' => 'PY',
        'GB-DV' => 'DV',
        'ES-PR' => 'PR',
        'NL-AN' => 'AN',
        'IR-IR' => 'IR',
        'GB-CI' => 'CI',
        'AZ-AZ' => 'AZ',
        'ML-ML' => 'ML',
        'AI-AI' => 'AI',
        'TZ-TZ' => 'TZ',
        'GB-LD' => 'LD',
        'GB-AT' => 'AT',
        'CH-MI' => 'MI',
        'GB-SH' => 'SH',
        'GB-MY' => 'MY',
        'GB-DN' => 'DN',
        'LT-LT' => 'LT',
        'NG-NG' => 'NG',
        'PT-23' => '23',
        'PH-PH' => 'PH',
        'GB-KE' => 'KE',
        'GB-ST' => 'ST',
        'BA-BA' => 'BA',
        'GB-CE' => 'CE',
        'CY-CY' => 'CY',
        'GB-DF' => 'DF',
        'AT-NO' => 'NiederÖsterreich',
        'AT-OO' => 'OberÖsterreich',
        'IN-01' => 'Andaman and Nicobar Islands',
        'IE-GW' => 'Galway',
        'IE-DB' => 'Dublin',
        'IE-WF' => 'Waterford',
        'IE-CK' => 'Cork',
        'IN-22' => 'Lakshadweep',
        'CN-110' => '110',
        'GR-49' => '49',
        'MX-AGS' => 'AGS',
        'PL-40' => '40',
        'MX-TLX' => 'TLX',
        'IE-KD' => 'KD',
        'MX-GTO' => 'GTO',
        'IE-WK' => 'WK',
        'ES-08' => '08',
        'NL-04' => '04',
        'CG-CG' => 'CG',
        'CH-VD' => 'VD',
        'MC-MC' => 'MC',
        'GB-LO' => 'LO',
        'CH-TI' => 'TI',
        'NL-01' => '01',
        'MA-MA' => 'MA',
        'BE-01' => '01',
        'AO-AO' => 'AO',
        'GR-06' => '06',
        'NL-07' => '07',
        'DE-11' => '11',
        'CZ-01' => '01',
        'SG-SG' => 'SG',
        'BT-BT' => 'BT',
        'RO-31' => '31',
        'DZ-DZ' => 'DZ',
        'SK-03' => '03',
        'PL-47' => '47',
        'IE-MT' => 'MT',
        'IE-MY' => 'MY',
        'IE-CL' => 'CL',
        'IE-LI' => 'LI',
        'FR-971' => '971',
        'GR-23' => '23',
        'SE-020' => '020',
        'FR-65' => '65',
        'FR-64' => '64',
        'FR-54' => '54',
        'CZ-02' => '02',
        'FR-76' => '76',
        'GB-SY' => 'SY',
        'PL-12' => '12',
        'PL-31' => '31',
        'CZ-03' => '03',
        'CZ-06' => '06',
        'PT-27' => '27',
        'ES-36' => '36',
        'FR-41' => '41',
        'DK-003' => '003',
        'DK-015' => '015',
        'DK-010' => '010',
        'RO-04' => '04',
        'GB-ES' => 'ES',
        'DK-012' => '012',
        'FR-21' => '21',
        'PL-27' => '27',
        'PL-21' => '21',
        'GR-33' => '33',
        'RO-39' => '39',
        'RO-38' => '38',
        'PT-40' => '40',
        'HU-08' => '08',
        'HU-12' => '12',
        'ES-43' => '43',
        'ES-50' => '50',
        'HR-07' => '07',
        'FR-29' => '29',
        'US-FL' => 'FL',
        'FR-35' => '35',
        'FI-006' => '006',
        'PL-08' => '08',
        'PL-13' => '13',
        'PL-19' => '19',
        'RO-21' => '21',
        'GR-07' => '07',
        'GR-19' => '19',
        'GR-21' => '21',
        'GR-37' => '37',
        'NO-10' => '10',
        'BE-07' => '07'
    };
}