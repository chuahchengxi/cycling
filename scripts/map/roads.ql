[out:json][timeout:900][maxsize:2000000000];
area["ISO3166-1"="SG"][admin_level=2]->.sg;
way["highway"~"^(motorway|motorway_link|trunk|trunk_link|primary|primary_link|secondary|secondary_link|tertiary|tertiary_link|unclassified|residential|living_street|service|cycleway|footway|path|pedestrian|track|steps|bridleway|corridor)$"](area.sg);
out tags geom;
