//
//  SheetView.swift
//  cyclingskibidi
//
//  Created by cheng xi on 23/5/26.
//

import SwiftUI

struct SheetView: View {
    @State var distanceEstimated = 10
    @State var timeEstimated = 40
    @State var difficultyEstimated = "easy"
    @State var uphillEstimated = 10
    @State var downhillEstimated = 15
    @Binding var currentDetent: PresentationDetent
    var body: some View {
        if currentDetent == .fraction(0.2) {
            Spacer()
                .frame(height:40)
            HStack {
                Text("\(distanceEstimated) km")
                    .bold()
                    .font(.title)
                    .padding()
                Text("\(timeEstimated) min")
                    .bold()
                    .font(.title)
                    .padding()
                Text("\(difficultyEstimated)")
                    .bold()
                    .font(.title)
                    .padding()
            }
            
            Button{
                
            }label:{
                Text("start")
                    .font(.title)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }else {
            VStack {
                HStack{
                    Text("\(distanceEstimated) km")
                        .bold()
                        .font(.title)
                        .padding()
                    Text("\(timeEstimated) min")
                        .bold()
                        .font(.title)
                        .padding()
                    Text("\(difficultyEstimated)")
                        .bold()
                        .font(.title)
                        .padding()
                }
                .padding()
                HStack {
                    VStack(alignment: .leading) {
                        Text("Uphill:\(uphillEstimated) km ↗")
                            .bold()
                            .font(.title)
                            .multilineTextAlignment(.leading)
                        Text("Downhill:\(downhillEstimated) km ↘")
                            .bold()
                            .font(.title)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer()
                }
                .padding()
                Image("graph1")
                    .resizable()
                    .scaledToFit()
                    .clipped()
                Button{
                    
                }label:{
                    Text("start")
                        .font(.title)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
}


#Preview {
    SheetView(currentDetent: .constant(.large))
}
