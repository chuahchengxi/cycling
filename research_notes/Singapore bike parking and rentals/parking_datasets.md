# Singapore bicycle parking open datasets (for offline bundling), as of 20 Nov 2026

## 1. LTA DataMall "Bicycle Parking" API (v3)

### Takeaway
DataMall's Bicycle Parking API is LTA's current, monthly-refreshed source. Version 3 launched on 30 Oct 2026 and adds `SharedBicycleParking` and `Type`. It is queried only by point plus radius, with an AccountKey header and pages of 500 records. You pull the whole island by tiling or with a large `Dist`. The data falls under the Singapore Open Data Licence, which allows redistribution with attribution.

### Cited Findings
- Source document: *LTA DataMall API User Guide & Documentation*, Version 6.11, dated 30 Oct 2026 (83 pp). Change log: "6.11 New Bicycle Parking API (version 3) is launched! Shared_Bicycle_Parking and Type are added. 30 Oct 2026". The original API launched in v4.9 on 11 Feb 2019. — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- Endpoint: `https://datamall2.mytransport.sg/ltaodataservice/v3/BicycleParking`. "Returns bicycle parking locations within a radius. The default radius is set as 0.5km". Update frequency: **Monthly** (section 2.21, p.43). — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- Request parameters: `Lat` (mandatory, e.g. 1.364897), `Long` (mandatory, e.g. 103.766094), `Dist` (optional, radius in km, default 0.5). The guide states **no maximum `Dist`**. — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- Response fields, with the guide's examples:
  - `Description` ("Bus Stop 43267")
  - `Latitude` (1.3927176306916775)
  - `Longitude` (103.82618266340947)
  - `RackType`, "Ownership and type of bicycle parking facility" ("Racks or Yellow Box")
  - `RackCount`, "Total number of bicycle parking lots" (10)
  - `ShelterIndicator` ("Y")
  - `SharedBicycleParking`, "Indication if the bicycle parking facility allows for shared bicycle parking" ("Yes")
  - `Type`, "Type of bicycle parking facility" ("RACK")

  — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- Authentication: GET request with the `AccountKey` request header. JSON is the default; send `accept: application/atom+xml` for XML (section 1). — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- Paging: "API responses returned are limited to 500 records of the dataset per call. This number may be adjusted from time to time." Use `$skip=500`, `$skip=1000` and so on. Table 1 lists only Bus Arrival, Train Service Alerts, Passenger Volume and Taxi Stands as exceptions, so Bicycle Parking is subject to the 500 cap. — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- The Geospatial Whole Island API (section 2.22, Annex E) has 34 SHP layers. They include `CyclingPath`, `CoveredLinkWay`, `Footpath` and `TrainStationExit`, but **no bicycle-parking layer**. — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)
- API Terms of Service:
  - Licence: "Use of the datasets is governed by the Singapore Open Data Licence."
  - Rate limit (cl. 4): "You can call the APIs up to 10 million times a day (the 'Threshold')". Exceeding it can lead to suspension "without warning", and the Threshold may change.
  - Credentials must be kept "secure and confidential" (cl. 10(b)).
  - Access may be terminated "for any reason whatsoever" (cl. 17).

  — [LTA API Terms of Service](https://datamall.lta.gov.sg/content/datamall/en/api-terms-of-service.html)
- Singapore Open Data Licence v1.0:
  - Grant: "worldwide, perpetual, royalty-free, non-exclusive licence" to "use, access, download, copy, distribute, transmit, modify and adapt the datasets", "whether commercially or non-commercially".
  - Sub-licensing to your app's or website's users is allowed where needed.
  - Attribution: you must show a conspicuous notice that acknowledges the source and links to the licence. Template: "Contains information from {name of dataset} accessed on {date} from {source} which is made available under the terms of the Singapore Open Data Licence version 1.0 {URL}".
  - You may not imply Agency endorsement.
  - No rights are granted over personal data, third-party rights, or patents, trademarks and designs.

  — [Singapore Open Data Licence](https://data.gov.sg/open-data-licence)

### Inferences
- **Whole-island pull by tiling is feasible.** Singapore spans about 50 km x 27 km. A grid of points spaced about 2 km apart, with `Dist` around 1.5 km to give overlap, comes to roughly 300–400 calls. Paginate each with `$skip` until a page returns fewer than 500 records, then dedupe on (Latitude, Longitude, Description). That is far below the 10M/day threshold. An alternative is a few centre points with a large `Dist` (e.g. 30 km) plus heavy `$skip` paging. Whether the server caps `Dist` is undocumented, so test it.
- **Bundling offline should be allowed.** The licence expressly permits copying and distributing the data. Two conditions follow. Show the attribution notice in the app, e.g. "Contains information from Bicycle Parking accessed on {date} from LTA DataMall…". Never ship the AccountKey in the app: do the pull at build time or on your own server.
- **Shared bikes:** `RackType` ("Racks or Yellow Box"), `Type` and `SharedBicycleParking` together should let the app flag yellow boxes and shared-bike-eligible parking.

### Gaps
- No total record count was found. I did not call the API because no key was available.
- Not found: the maximum `Dist`, the exact enumerated values of `RackType` and `Type`, and whether v2 or v1 endpoints remain live after v3.
- The DataMall portal's general Terms of Use page (https://datamall.lta.gov.sg/content/datamall/en/term-of-use.html) was not reviewed in full.

## 2. data.gov.sg / URA / NParks / HDB downloadable datasets

### Takeaway
The only downloadable government bicycle-parking file found is LTA's "LTA Bicycle Rack (GEOJSON)" on data.gov.sg. It holds 396 points and 19,329 rack lots, and every record carries a July 2019 timestamp. It is stale and covers a small fraction of the island's lots. I found no dedicated URA, NParks or HDB bicycle-parking dataset.

### Cited Findings
- Dataset "LTA Bicycle Rack (GEOJSON)"
  - ID: `d_937424cca6d1617288a82a7aeb89f76d`
  - Agency: LTA. Format: GeoJSON, 235 KB.
  - Dates: created 24 Jan 2019; listing "last updated" 06 Jun 2024.
  - Licence: Singapore Open Data Licence ("Free forever for personal or commercial use").
  - Rate limits on the data.gov.sg API are noted as enforced from 31 Dec 2025.

  — [data.gov.sg dataset page](https://data.gov.sg/datasets/d_937424cca6d1617288a82a7aeb89f76d/view)
- Download: `GET https://api-open.data.gov.sg/v1/public/api/datasets/d_937424cca6d1617288a82a7aeb89f76d/poll-download` returns `data.url`, a pre-signed S3 link that expires after 3600 s. Verified on 20 Nov 2026. — [data.gov.sg dataset page](https://data.gov.sg/datasets/d_937424cca6d1617288a82a7aeb89f76d/view)
- Contents, from my own download and parse on 20 Nov 2026:
  - **396 Point features**, bounding box lon 103.636–103.962, lat 1.270–1.449. Points are spread island-wide.
  - Properties are `Name` (e.g. "kml_1") and `Description`. `Description` is an HTML table from a KML export holding `SHLTR_IND` (Yes/No), `TYP_CD`, `RACK_CNT`, `INC_CRC` and `FMEL_UPD_D`.
  - `TYP_CD` counts: Single 274, Double 85, Yellow-box 37.
  - `SHLTR_IND` counts: No 211, Yes 178, blank 7.
  - Sum of `RACK_CNT`: **19,329** lots.
  - Every `FMEL_UPD_D` is 20190703162212–20190703162213, which means **all records date from 3 Jul 2019**.

  — [data.gov.sg dataset page](https://data.gov.sg/datasets/d_937424cca6d1617288a82a7aeb89f76d/view)
- Island-wide scale for comparison:
  - An MOT/LTA reply (date unclear) says about 40,000 lots were added, for **over 246,000 bicycle parking lots** island-wide. This figure comes via a search snippet; I could not confirm its date.
  - A 2022 reply gives about 27,000 lots across 127 MRT stations and Integrated Transport Hubs.

  — [MOT newsroom search results](https://www.mot.gov.sg/news-resources/newsroom/oral-reply-by-senior-parliamentary-secretary-for-transport-baey-yam-keng-to-parliamentary-question-on-meeting-demand-for-bicycle-parking-lots/)
- HDB provides one bicycle lot per six dwelling units, and LTA is reviewing additional designated shared-bike spaces with HDB (Mar 2026 reply, via search snippet). — [WP written answers 6 Mar 2026](https://www.wp.sg/parliament/written-answers-to-wps-oral-questions-and-written-questions-on-06-mar-2026)
- The developers-provision reply is dated 4 Jul 2023. It says minimum bicycle-parking provisions have been imposed since 2018 but gives no counts. — [MOT reply](https://www.mot.gov.sg/news-resources/newsroom/written-reply-to-parliamentary-question-on-provision-of-bicycle-parking-by-developers/)

### Inferences
- The data.gov.sg file is too old (2019) and too sparse (about 19k of roughly 246k lots) to serve as the primary source. It works as a no-key fallback or seed. The DataMall v3 API is the fresher, more complete feed.
- The "last updated 06 Jun 2024" label likely reflects a metadata or republish change, not a data refresh, because every record's update stamp is 2019.

### Gaps
- No URA, NParks or HDB bicycle-rack datasets were found on data.gov.sg in search. NParks park-connector bike parking and HDB void-deck racks have no separate public file that I could find. HDB racks may appear inside the DataMall feed, but that is unverified.
- The date of the 246,000-lot figure is unconfirmed.

## 3. Yellow boxes / designated shared-bicycle (QR code) parking

### Takeaway
LTA runs the QR-code parking system for shared bikes, in force since 14 Jan 2019. Designated parking covers yellow boxes and bicycle racks. No standalone public dataset of QR-code locations was found. The new DataMall v3 fields (`RackType` "Yellow Box", `SharedBicycleParking`) are the closest official source. No current official count of yellow boxes was found.

### Cited Findings
- LTA's QR-code parking system for bicycle-sharing took effect on 14 Jan 2019. Users must scan the QR code at a designated parking place to end the trip. — [LTA news release Dec 2018](https://lta.gov.sg/content/ltagov/en/newsroom/2018/12/2/qr-code-parking-system-for-bicycle-sharing-to-take-effect-on-14-january-2019.html)
- QR codes were to be placed at all acceptable parking areas, including yellow boxes and bicycle racks (launch-era reporting, 2018). — [Vulcan Post](https://vulcanpost.com/648220/qr-code-bike-parking-singapore/)
- About 95% of shared-bike trips from Jan 2025 to Jul 2026 ended at designated parking areas. Feedback on badly parked shared bikes numbered about 12,000 in 2025 and 15,000 in Jan–Jul 2026. This comes from a Sept 2026 reply, via search snippet. — [MOT: Holding operators accountable](https://www.mot.gov.sg/news-resources/newsroom/holding-bicycle-sharing-operators-accountable-for-bicycles-parked-outside-designated-zones-/)
- The 2019 data.gov.sg rack file contains 37 `TYP_CD = Yellow-box` records (my parse, above). — [data.gov.sg dataset](https://data.gov.sg/datasets/d_937424cca6d1617288a82a7aeb89f76d/view)
- An OSM contributor (diary, 2 Jul 2023) says "neither the parking spots nor the associated QR-codes are available for download by the general public". They hand-survey these spots in Hougang and Sengkang, tagged as follows. — [OSM diary ADsdfjk23](https://www.openstreetmap.org/user/ADsdfjk23/diary/401848)
  - `amenity=bicycle_rental`
  - `bicycle_rental=dropoff_point`
  - `network=LTA QR Code Parking System`
  - `operator=Land Transport Authority`
  - `ref=<QR value>`
  - `covered=yes/no`
- DataMall v3 (30 Oct 2026) exposes `RackType` (example "Racks or Yellow Box") and `SharedBicycleParking` ("Yes"). — [API User Guide PDF](https://datamall.lta.gov.sg/content/dam/datamall/datasets/LTA_DataMall_API_User_Guide.pdf)

### Inferences
- Because v3 was released only three weeks ago with shared-parking flags, it is likely now the de facto public yellow-box and shared-parking dataset. Confirm by pulling it with a key.

### Gaps
- Not found: an official current count of yellow boxes or QR-code parking locations.
- Not found: any public list of QR codes or IDs.

## 4. OpenStreetMap: counts, tags, completeness, ODbL

### Takeaway
Geofabrik's regional taginfo (data to 19 Nov 2026) covers Malaysia, Singapore and Brunei together. It shows 972 `amenity=bicycle_parking` and 207 `amenity=bicycle_rental` objects in that combined region, so the Singapore-only count is lower. OSM is far less complete than LTA's data and does not record lot counts systematically. Bundling OSM data triggers ODbL attribution and share-alike obligations.

### Cited Findings
- Geofabrik taginfo, region "Malaysia, Singapore, and Brunei" (`data_until` 2026-11-19T20:55:17Z):
  - `amenity=bicycle_parking`: 972 total (841 nodes, 129 ways, 2 relations).
  - `amenity=bicycle_rental`: 207 total (188 nodes, 19 ways).

  — [taginfo bicycle_parking API](https://taginfo.geofabrik.de/asia:malaysia-singapore-brunei/api/4/tag/stats?key=amenity&value=bicycle_parking); [taginfo bicycle_rental API](https://taginfo.geofabrik.de/asia:malaysia-singapore-brunei/api/4/tag/stats?key=amenity&value=bicycle_rental)
- Singapore OSM tagging for QR drop-off points: `amenity=bicycle_rental` + `bicycle_rental=dropoff_point`, with `covered`, `network`, `operator` and `ref` (2023, partial, Hougang/Sengkang only). — [OSM diary](https://www.openstreetmap.org/user/ADsdfjk23/diary/401848)
- No formal OSM import of LTA bicycle-parking data was found. There is a precedent: a 2022 covered-linkway import from DataMall, done with LTA permission under the Singapore Open Data Licence after licence questions on the imports list. — [OSM imports list, Sept 2022](https://lists.openstreetmap.org/pipermail/imports/2022-September/006953.html)

### Inferences
- At most about 972 OSM parking objects, versus 246,000+ official lots spread over many thousands of sites, means OSM coverage is very incomplete. LTA DataMall should be the primary source. OSM is useful only as a supplement, such as private or mall racks.
- ODbL obligations if OSM data is bundled:
  - Attribute "© OpenStreetMap contributors" with a link to the licence.
  - A modified database (e.g. a merged LTA+OSM file) that is publicly distributed must be offered under ODbL. Keeping OSM-derived and LTA-derived layers as separate databases avoids share-alike reaching the LTA data.
  - This is a general ODbL summary, not fetched this session; check it against https://www.openstreetmap.org/copyright.

### Gaps
- No Singapore-only OSM count: the Overpass count query failed (empty response from overpass-api.de and kumi mirror) and was not retried, to avoid hammering.
- `capacity` and `covered` fill rates are not available: the taginfo combinations endpoint returned no data.
- The ODbL details above are not cited from a fetched source this session.
